# GLM for a Bernoulli outcome with optional Gaussian or t priors
functions {
  /** 
   * Apply inverse link function to linear predictor
   * see help(binom) in R
   *
   * @param eta Linear predictor vector
   * @param link An integer indicating the link function
   * @return A vector, i.e. inverse-link(eta)
   */
  vector linkinv_bern(vector eta, int link) {
    vector[rows(eta)] pi;
    if (link < 1 || link > 5) reject("Invalid link");
    if      (link == 1)
      for(n in 1:rows(eta)) pi[n] <- inv_logit(eta[n]);
    else if (link == 2)
      for(n in 1:rows(eta)) pi[n] <- Phi(eta[n]);
    else if (link == 3) 
      for(n in 1:rows(eta)) pi[n] <- cauchy_cdf(eta[n], 0.0, 1.0);
    else if (link == 4) 
      for(n in 1:rows(eta)) pi[n] <- exp(eta[n]);
    else if (link == 5) 
      for(n in 1:rows(eta)) pi[n] <- inv_cloglog(eta[n]);
    return pi;
  }

  /**
   * Increment with the unweighted log-likelihood
   * @param link An integer indicating the link function
   * @param eta0 A vector of linear predictors | y = 0
   * @param eta1 A vector of linear predictors | y = 1
   * @param N An integer array of length 2 giving the number of 
   *   observations where y = 0 and y = 1 respectively
   * @return lp__
   */
  real ll_bern_lp(vector eta0, vector eta1, int link, int[] N) {
    if (link < 1 || link > 5) reject("Invalid link");
    if (link == 1) { // logit link
      0 ~ bernoulli_logit(eta0);
      1 ~ bernoulli_logit(eta1);
    }
    else if (link == 2) { // probit link
      increment_log_prob(normal_ccdf_log(eta0, 0, 1));
      increment_log_prob(normal_cdf_log(eta1, 0, 1));
    }
    else if (link == 3) { // cauchit link
      increment_log_prob(cauchy_ccdf_log(eta0, 0, 1));
      increment_log_prob(cauchy_cdf_log(eta1, 0, 1));
    }
    else if(link == 4) { // log link
      vector[N[1]]       log_pi0;
      for (n in 1:N[1])  log_pi0[n] <- log1m_exp(eta0[n]);
      increment_log_prob(log_pi0);
      increment_log_prob(eta1); # already in log form
    }
    else if(link == 5) { // cloglog link
      vector[N[2]]       log_pi1;
      for (n in 1:N[2])  log_pi1[n] <- log1m_exp(-exp(eta1[n]));
      increment_log_prob(log_pi1);
      increment_log_prob(-exp(eta0));
    }
    return get_lp();
  }

  /** 
   * Pointwise (pw) log-likelihood vector
   *
   * @param y The integer outcome variable. Note that function is
   *  called separately with y = 0 and y = 1
   * @param eta Vector of linear predictions
   * @param link An integer indicating the link function
   * @return A vector
   */
  vector pw_bern(int y, vector eta, int link) {
    vector[rows(eta)] ll;
    if (link < 1 || link > 5) 
      reject("Invalid link");
    if (link == 1) { # link = logit
      for (n in 1:rows(eta)) ll[n] <- bernoulli_logit_log(y, eta[n]);
    }
    else { # link = probit, cauchit, log, or cloglog 
           # Note: this may not be numerically stable
      vector[rows(eta)] pi;
      pi <- linkinv_bern(eta, link);
      for (n in 1:rows(eta)) ll[n] <- bernoulli_log(y, pi[n]) ;
    }
    return ll;
  }

  /** 
   * Upper bound on the intercept, which is infinity except for log link
   *
   * @param link An integer indicating the link function
   * @param X0 A matrix of predictors | y = 0
   * @param X1 A matrix of predictors | y = 1
   * @param beta A vector of coefficients
   * @param has_offset An integer indicating an offset
   * @param offset0 A vector of offsets | y = 0
   * @param offset1 A vector of offsets | y = 1
   * @return A scalar upper bound on the intercept
   */
  real make_upper_bernoulli(int link, matrix X0, matrix X1, 
                            vector beta, int has_offset, 
                            vector offset0, vector offset1) {
    real maximum;
    if (link != 4) return positive_infinity();
    if (has_offset == 0) maximum <- fmax( max(X0 * beta), max(X1 * beta) );
    else
      maximum <- fmax( max(X0 * beta + offset0), max(X1 * beta + offset1) );
      
    return -maximum;
  }
  
  /** 
   * Create group-specific block-diagonal Cholesky factor, see section 2.3 of
   * https://cran.r-project.org/web/packages/lme4/vignettes/lmer.pdf
   * @param p An integer array with the number variables on the LHS of each |
   * @param tau Vector of scale parameters for the decomposed covariance matrices
   * @param scale Vector of scale hyperparameters
   * @param zeta Vector of positive parameters that are normalized into simplexes
   * @param rho Vector of radii in the onion method for creating Cholesky factors
   * @param z_T Vector used in the onion method for creating Cholesky factors
   * @return A vector that corresponds to theta in lme4
   */
  vector make_theta_L_bern(int len_theta_L, int[] p,
                           vector tau, vector scale, vector zeta,
                           vector rho, vector z_T) {
    vector[len_theta_L] theta_L;
    int zeta_mark;
    int z_T_mark;
    int rho_mark;
    int theta_L_mark;
    zeta_mark <- 1;
    z_T_mark <- 1;
    rho_mark <- 1;
    theta_L_mark <- 1;
    
    // each of these is a diagonal block of the implicit Cholesky factor
    for (i in 1:size(p)) { 
      int nc;
      nc <- p[i];
      if (nc == 1) { // "block" is just a standard deviation
        theta_L[theta_L_mark] <- tau[i] * scale[i];
        theta_L_mark <- theta_L_mark + 1;
      }
      else { // block is lower-triangular               
        matrix[nc,nc] T_i; 
        real trace_T_i;
        vector[nc] pi; // variance = proportion of trace_T_i
        real std_dev;
        real T21;
        
        trace_T_i <- square(tau[i] * scale[i]) * nc;
        pi <- segment(zeta, zeta_mark, nc); // zeta ~ gamma(shape, 1)
        pi <- pi / sum(pi);                 // thus pi ~ dirichlet(shape)
        zeta_mark <- zeta_mark + nc;
        std_dev <- sqrt(pi[1] * trace_T_i);
        T_i[1,1] <- std_dev;

        // Put a correlation into T_i[2,1] and scale by std_dev
        std_dev <- sqrt(pi[2] * trace_T_i);
        T21 <- 2.0 * rho[rho_mark] - 1.0;
        rho_mark <- rho_mark + 1;
        T_i[2,2] <- std_dev * sqrt(1.0 - square(T21));
        T_i[2,1] <- std_dev * T21;
        
        for (r in 2:(nc - 1)) { // scaled onion method
          int rp1;
          vector[r] T_row;
          real scale_factor;
          T_row <- segment(z_T, z_T_mark, r);
          z_T_mark <- z_T_mark + r;
          rp1 <- r + 1;
          std_dev <- sqrt(pi[rp1] * trace_T_i);
          scale_factor <- sqrt(rho[rho_mark] / dot_self(T_row)) * std_dev;
          for(c in 1:r) T_i[rp1,c] <- T_row[c] * scale_factor;
          T_i[rp1,rp1] <- sqrt(1.0 - rho[rho_mark]) * std_dev;
          rho_mark <- rho_mark + 1;
        }
        
        // vec T_i
        for (c in 1:nc) for (r in c:nc) {
          theta_L[theta_L_mark] <- T_i[r,c];
          theta_L_mark <- theta_L_mark + 1;
        }
      }
    }
    return theta_L;
  }
  
  /** 
   * Create group-specific coefficients, see section 2.3 of
   * https://cran.r-project.org/web/packages/lme4/vignettes/lmer.pdf
   *
   * @param z_b Vector whose elements are iid normal(0,sigma) a priori
   * @param theta Vector with covariance parameters
   * @param p An integer array with the number variables on the LHS of each |
   * @param l An integer array with the number of levels for the factor(s) on 
   *   the RHS of each |
   * @return A vector of group-specific coefficients
   */
  vector make_b_bern(vector z_b, vector theta_L, int[] p, int[] l) { 
    vector[rows(z_b)] b;
    int b_mark;
    int theta_L_mark;
    b_mark <- 1;
    theta_L_mark <- 1;
    for (i in 1:size(p)) {
      int nc;
      nc <- p[i];
      if (nc == 1) {
        real theta_L_start;
        theta_L_start <- theta_L[theta_L_mark]; // needs to be positive
        for (s in b_mark:(b_mark + l[i] - 1)) 
          b[s] <- theta_L_start * z_b[s];
        b_mark <- b_mark + l[i];
        theta_L_mark <- theta_L_mark + 1;
      }
      else {
        matrix[nc,nc] T_i;
        T_i <- rep_matrix(0, nc, nc);
        for (c in 1:nc) {
          T_i[c,c] <- theta_L[theta_L_mark];    // needs to be positive
          theta_L_mark <- theta_L_mark + 1;
          for(r in (c+1):nc) {
            T_i[r,c] <- theta_L[theta_L_mark];
            theta_L_mark <- theta_L_mark + 1;
          }
        }
        for (j in 1:l[i]) {
          vector[nc] temp;
          temp <- T_i * segment(z_b, b_mark, nc);
          b_mark <- b_mark - 1;
          for (s in 1:nc) b[b_mark + s] <- temp[s];
          b_mark <- b_mark + nc + 1;
        }
      }
    }
    return b;
  }

}
data {
  # dimensions
  int<lower=0> K;                # number of predictors
  int<lower=1> N[2];             # number of observations where y = 0 and y = 1 respectively
  vector[K] xbar;                # vector of column-means of rbind(X0, X1)
  matrix[N[1],K] X0;             # centered (by xbar) predictor matrix | y = 0
  matrix[N[2],K] X1;             # centered (by xbar) predictor matrix | y = 1
  int<lower=0,upper=1> prior_PD; # flag indicating whether to draw from the prior predictive
  
  # intercept
  int<lower=0,upper=1> has_intercept; # 0 = no, 1 = yes
  
  # glmer stuff, see table 3 of
  # https://cran.r-project.org/web/packages/lme4/vignettes/lmer.pdf
  int<lower=0> t;                   # num. terms (maybe 0) with a | in the glmer formula
  int<lower=1> p[t];                # num. variables on the LHS of each |
  int<lower=1> l[t];                # num. levels for the factor(s) on the RHS of each |
  int<lower=0> q;                   # conceptually equals \sum_{i=1}^t p_i \times l_i
  int<lower=0> num_non_zero[2];     # number of non-zero elements in the Z matrices
  vector[num_non_zero[1]] w0;       # non-zero elements in the implicit Z0 matrix
  vector[num_non_zero[2]] w1;       # non-zero elements in the implicit Z1 matrix
  int<lower=0> v0[num_non_zero[1]]; # column indices for w0
  int<lower=0> v1[num_non_zero[2]]; # column indices for w1
  int<lower=0> u0[(N[1]+1)*(t>0)];  # where the non-zeros start in each row of Z0
  int<lower=0> u1[(N[2]+1)*(t>0)];  # where the non-zeros start in each row of Z1
  int<lower=0> len_theta_L;         # length of the theta_L vector

  # link function from location to linear predictor
  int<lower=1,upper=5> link;
  
  # weights
  int<lower=0,upper=1> has_weights; # 0 = No, 1 = Yes
  vector[N[1] * has_weights] weights0;
  vector[N[2] * has_weights] weights1;
  
  # offset
  int<lower=0,upper=1> has_offset;  # 0 = No, 1 = Yes
  vector[N[1] * has_offset] offset0;
  vector[N[2] * has_offset] offset1;

  # prior family: 0 = none, 1 = normal, 2 = student_t, 3 = horseshoe, 4 = horseshoe_plus
  int<lower=0,upper=4> prior_dist;
  int<lower=0,upper=2> prior_dist_for_intercept;
  
  # hyperparameter values
  vector<lower=0>[K] prior_scale;
  real<lower=0> prior_scale_for_intercept;
  vector[K] prior_mean;
  real prior_mean_for_intercept;
  vector<lower=0>[K] prior_df;
  real<lower=0> prior_df_for_intercept;

  # hyperparameters for glmer stuff; if t > 0 priors are mandatory
  vector<lower=0>[t] gamma_shape; 
  vector<lower=0>[t] scale;
  int<lower=0> len_concentration;
  real<lower=0> concentration[len_concentration];
  int<lower=0> len_shape;
  real<lower=0> shape[len_shape];
}
transformed data {
  int NN;
  int<lower=0> horseshoe;
  int<lower=0> len_z_T;
  int<lower=0> len_var_group;
  int<lower=0> len_rho;
  real<lower=0> delta[len_concentration];
  int<lower=1> pos;
  
  NN <- N[1] + N[2];
  if (prior_dist <  2) horseshoe <- 0;
  else if (prior_dist == 3) horseshoe <- 2;
  else if (prior_dist == 4) horseshoe <- 4;
  len_z_T <- 0;
  len_var_group <- sum(p) * (t > 0);
  len_rho <- sum(p) - t;
  pos <- 1;
  for (i in 1:t) {
    if (p[i] > 1) {
      for (j in 1:p[i]) {
        delta[pos] <- concentration[j];
        pos <- pos + 1;
      }
    }
    for (j in 3:p[i]) len_z_T <- len_z_T + p[i] - 1;
  }
}
parameters {
  vector[K] z_beta;
  real<upper=if_else(link == 4, 0, positive_infinity())> gamma[has_intercept];
  real<lower=0> global[horseshoe];
  vector<lower=0>[K] local[horseshoe];
  vector[q] z_b;
  vector[len_z_T] z_T;
  vector<lower=0,upper=1>[len_rho] rho;
  vector<lower=0>[len_concentration] zeta;
  vector<lower=0>[t] tau;
}
transformed parameters {
  vector[K] beta;
  vector[q] b;
  vector[len_theta_L] theta_L;
  if (prior_dist == 0) beta <- z_beta;
  else if (prior_dist <= 2) beta <- z_beta .* prior_scale + prior_mean;
  else if (prior_dist == 3) {
    vector[K] lambda;
    for (k in 1:K) lambda[k] <- local[1][k] * sqrt(local[2][k]);
    beta <- z_beta .* lambda * global[1]    * sqrt(global[2]);
  }
  else if (prior_dist == 4) {
    vector[K] lambda;
    vector[K] lambda_plus;
    for (k in 1:K) {
      lambda[k] <- local[1][k] * sqrt(local[2][k]);
      lambda_plus[k] <- local[3][k] * sqrt(local[4][k]);
    }
    beta <- z_beta .* lambda .* lambda_plus * global[1] * sqrt(global[2]);
  }
  if (t > 0) {
    theta_L <- make_theta_L_bern(len_theta_L, p, 
                                 tau, scale, zeta, rho, z_T);
    b <- make_b_bern(z_b, theta_L, p, l);
  }
}
model {
  vector[N[1]] eta0;
  vector[N[2]] eta1;
  if (K > 0) {
    eta0 <- X0 * beta;
    eta1 <- X1 * beta;
  }
  else {
    eta0 <- rep_vector(0.0, N[1]);
    eta1 <- rep_vector(0.0, N[2]);
  }
  if (has_offset == 1) {
    eta0 <- eta0 + offset0;
    eta1 <- eta1 + offset1;
  }
  if (t > 0) {
    eta0 <- eta0 + csr_matrix_times_vector(N[1], q, w0, v0, u0, b);
    eta1 <- eta1 + csr_matrix_times_vector(N[2], q, w1, v1, u1, b);
  }
  if (has_intercept == 1) {
    if (link != 4) {
      eta0 <- gamma[1] + eta0;
      eta1 <- gamma[1] + eta1;
    }
    else {
      real shift;
      shift <- fmax(max(eta0), max(eta1));
      eta0 <- gamma[1] + eta0 - shift;
      eta1 <- gamma[1] + eta1 - shift;
    }
  }
  
  // Log-likelihood 
  if (has_weights == 0 && prior_PD == 0) { # unweighted log-likelihoods
    real dummy; # irrelevant but useful for testing
    dummy <- ll_bern_lp(eta0, eta1, link, N);
  }
  else if (prior_PD == 0) { # weighted log-likelihoods
    increment_log_prob(dot_product(weights0, pw_bern(0, eta0, link)));
    increment_log_prob(dot_product(weights1, pw_bern(1, eta1, link)));
  }
  
  // Log-priors for coefficients
  if      (prior_dist == 1) z_beta ~ normal(0, 1);
  else if (prior_dist == 2) z_beta ~ student_t(prior_df, 0, 1);
  else if (prior_dist == 3) { # horseshoe
    z_beta ~ normal(0,1);
    local[1] ~ normal(0,1);
    local[2] ~ inv_gamma(0.5 * prior_df, 0.5 * prior_df);
    global[1] ~ normal(0,1);
    global[2] ~ inv_gamma(0.5, 0.5);
  }
  else if (prior_dist == 4) { # horseshoe+
    z_beta ~ normal(0,1);
    local[1] ~ normal(0,1);
    local[2] ~ inv_gamma(0.5 * prior_df, 0.5 * prior_df);
    local[3] ~ normal(0,1);
    // unorthodox useage of prior_scale as another df hyperparameter
    local[4] ~ inv_gamma(0.5 * prior_scale, 0.5 * prior_scale);
    global[1] ~ normal(0,1);
    global[2] ~ inv_gamma(0.5, 0.5);
  }
  /* else prior_dist is 0 and nothing is added */
   
  // Log-prior for intercept  
  if (has_intercept == 1) {
    if (prior_dist_for_intercept == 1) # normal
      gamma ~ normal(prior_mean_for_intercept, prior_scale_for_intercept);
    else if (prior_dist_for_intercept == 2) # student_t
      gamma ~ student_t(prior_df_for_intercept, prior_mean_for_intercept, 
                        prior_scale_for_intercept);
    /* else prior_dist = 0 and nothing is added */
  }
  
  if (t > 0) {
    int pos_shape;
    int pos_rho;
    z_b ~ normal(0,1);
    z_T ~ normal(0,1);
    pos_shape <- 1;
    pos_rho <- 1;
    for (i in 1:t) if (p[i] > 1) {
      vector[p[i] - 1] shape1;
      vector[p[i] - 1] shape2;
      real nu;
      nu <- shape[pos_shape] + 0.5 * (p[i] - 2);
      pos_shape <- pos_shape + 1;
      shape1[1] <- nu;
      shape2[1] <- nu;
      for (j in 2:(p[i]-1)) {
        nu <- nu - 0.5;
        shape1[j] <- 0.5 * j;
        shape2[j] <- nu;
      }
      segment(rho, pos_rho, p[i] - 1) ~ beta(shape1,shape2);
      pos_rho <- pos_rho + p[i] - 1;
    }
    zeta ~ gamma(delta, 1);
    tau ~ gamma(gamma_shape, 1);
  }
}
generated quantities {
  real alpha[has_intercept];
  real mean_PPD;
  if (has_intercept == 1) {
    alpha[1] <- gamma[1] - dot_product(xbar, beta);
  }
  mean_PPD <- 0;
  {
    vector[N[1]] eta0; 
    vector[N[2]] eta1;
    vector[N[1]] pi0;
    vector[N[2]] pi1;
    if (K > 0) {
      eta0 <- X0 * beta;
      eta1 <- X1 * beta;
    }
    else {
      eta0 <- rep_vector(0.0, N[1]);
      eta1 <- rep_vector(0.0, N[2]);
    }
    if (has_offset == 1) {
      eta0 <- eta0 + offset0;
      eta1 <- eta1 + offset1;
    }
    if (t > 0) {
      eta0 <- eta0 + csr_matrix_times_vector(N[1], q, w0, v0, u0, b);
      eta1 <- eta1 + csr_matrix_times_vector(N[2], q, w1, v1, u1, b);
    }
    if (has_intercept == 1) {
      if (link != 4) {
        eta0 <- gamma[1] + eta0;
        eta1 <- gamma[1] + eta1;
      }      
      else {
        real shift;
        shift <- fmax(max(eta0), max(eta1));
        eta0 <- gamma[1] + eta0 - shift;
        eta1 <- gamma[1] + eta1 - shift;
        alpha[1] <- alpha[1] - shift;
      }
    }
    pi0 <- linkinv_bern(eta0, link);
    pi1 <- linkinv_bern(eta1, link);
    for (n in 1:N[1]) mean_PPD <- mean_PPD + bernoulli_rng(pi0[n]);
    for (n in 1:N[2]) mean_PPD <- mean_PPD + bernoulli_rng(pi1[n]);
    mean_PPD <- mean_PPD / NN;
  }
}

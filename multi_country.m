% see MATLAB Tutorial on how to run CUDA or PTX Code on GPU:
% http://www.mathworks.com/help/distcomp/run-cuda-or-ptx-code-on-gpu.html
clear%; profile off
max_iter=10000; disp_iter=100;
N     = 10;     % Number of countries
gam   = 1;      % Utility-function parameter
alpha = 0.36;   % Capital share in output
beta  = 0.99;   % Discount factor
delta = 0.025;  % Depreciation rate 
rho   = 0.95;   % Persistence of the log of the productivity level
Sigma = 0.01^2*(eye(N)+ones(N)); % Covariance matrix of shocks to the log of the productivity level
A=(1/beta-1+delta)/alpha; D=2*N;
mu = [repmat(3,1,N) repmat(2,1,N)]; % States: k[1..N], a[1..N]
if any(size(mu)~=[1,D]); error('mu must be a row vector of length %d',D); end
gssa=false; % use initial guess from GSSA
if gssa
    addpath('Smolyak_Anisotropic_JMMV_2014')
    load(sprintf('gssa_N=%d.mat',N));
    xm=(min_simul+max_simul)/2; xs=(max_simul-min_simul)/2;
    clear min_simul max_simul
else
    xm=ones(1,D); xs=repmat(0.2,1,D); % set mean xm to steady state and spread xs to 20% away
end
[B,X,S]=smolyak(mu,xm,xs);
if gssa % to check with JMMV reorder rows using j indices
    [~,i]=sortrows(Smolyak_Elem_Anisotrop(Smolyak_Elem_Isotrop(D,max(mu)),mu));
    [~,j]=sortrows(S); [~,j]=sort(j); i=i(j); clear j
end

J=11;
if J>10
    [e,w]=monomial(N,Sigma,J-10); % M1 or M2 monomial rule
else
    [e,w]=gauher(J,Sigma); % Gauss-Hermite quadrature with J nodes
end
e=exp(e)';

J=size(e,2);
M=size(B,1);
L=M*J;

k=X(:,1:N); a=X(:,N+1:2*N); clear X
ap=reshape(bsxfun(@times,repmat(a.^rho,1,J),e(:)'),M,N,J);
x=[nan(N,L); reshape(permute(ap,[2 1 3]),N,L)];

gpu = gpuDeviceCount;
if gpu
    setenv('MATLAB_WORKER_ARGS',sprintf('--gres=gpu:%d',gpu))
    p = gcp('nocreate'); % If no pool, do not create new one.
    if isempty(p)
        parpool(gpu)
    elseif p.NumWorkers ~= gpu
        delete(p)
        parpool(gpu)
    end
    cmd = sprintf('nvcc -arch=sm_35 -ptx smolyak_kernel.cu -DD=%d -DM=%d -DN=%d -DSMAX=%d -DMU_MAX=%d',D,M,N,2^max(mu),max(mu));
    disp(cmd);
    if system(cmd); error('nvcc failed'); end
    spmd
        gd = gpuDevice;
        fprintf('GPU%d: %s\n', gd.Index, gd.Name)
        kernel = parallel.gpu.CUDAKernel('smolyak_kernel.ptx', 'smolyak_kernel.cu');
        kernel.ThreadBlockSize = 128;
        kernel.GridSize = ceil(L/kernel.ThreadBlockSize(1));
        setConstantMemory(kernel,'xm',xm);
        setConstantMemory(kernel,'xs',xs);
        setConstantMemory(kernel,'s',uint8(S-1));
        kpp_=nan(N,L/gpu,'gpuArray');
        x=gpuArray(x(:,1+L/gpu*(labindex-1):L/gpu*labindex));
    end
else
    kpp=ones(M,N,J);
end
%% main loop
bfile=sprintf('b_N=%d_mu=%d.mat',N,max(mu));
if exist(bfile,'file')
    fprintf('loading %s\n',bfile)
    load(bfile)
elseif gssa
    b=smolyak(mu,0,1,S,simul_norm)\k_prime_GSSA;
else
    b=zeros(M,N); b(1,:)=1;
end
kp=B*b;
bdamp=0.05;
binvfile=sprintf('B_inv_N=%d_mu=%d.mat',N,max(mu));
if exist(binvfile,'file')
    fprintf('loading %s ... ',binvfile)
    load(binvfile)
    fprintf('done\n')
else
    B_inv=inv(B);
    save(binvfile,'B_inv')
end
if gpu
    spmd
        kp_=gpuArray(kp);
        B_inv=gpuArray(B_inv);
        b=gpuArray(b);
        % Measure the overhead introduced by calling the wait function.
        tover = inf;
        for itr = 1:100
            tic;
            wait(gd);
            tover = min(toc, tover);
        end
    end
end
t0=0; % total runtime
t1=0; % memcpy_in time
t2=0; % kernel time
t3=0; % memcpy_out time
t4=0; % host time
t5=0; % host time
t6=0; % host time
fprintf('Iter\tGFLOPS\tMemcpy_IN, MB/s\tMemcpy_OUT, MB/s\tcollect\tcpu\tgemm\tRuntime\tDiff\n')
%profile on
tic
%%
for it=1:max_iter
    if any(kp(:)<0); error('negative capital'); end
    if it==10; bdamp=0.1; end
    if gpu
        spmd
tmp=tic;
            x(1:N,:)=repmat(kp_',1,J/gpu);
t1=t1+toc(tmp);
tmp=tic;
            kpp_ = feval(kernel, x, kpp_, L/gpu, b);
            wait(gd);
t2=t2+toc(tmp)-tover;
tmp=tic;
%            kpp(:,1+L/gpu*(labindex-1):L/gpu*labindex) = gather(kpp_);
            kpp = gather(kpp_);
            wait(gd);
t3=t3+toc(tmp);
        end
tmp=tic;
        t1=t1{1};t2=t2{1};t3=t3{1};
%         max(max(abs(kpp' - smolyak(mu,xm,xs,S,[X{:}]')*gather(b{1}))))
        kpp=permute(reshape([kpp{:}],N,M,J),[2 1 3]);
%         kpp=permute(reshape(kpp,N,M,J),[2 1 3]);
t4=t4+toc(tmp);
    else
        kpp=nan(M,N,J);
tmp=tic;
        for j=1:J
            kpp(:,:,j)=smolyak(mu,xm,xs,S,[kp ap(:,:,j)])*b;
        end
t2=t2+toc(tmp);
    end
tmp=tic;
    ucp=repmat(mean(bsxfun(@plus,bsxfun(@times,A*kp.^alpha,ap)-kpp,(1-delta)*kp),2).^-gam,1,N,1);
%     ucp=repmat(mean(A*kp.^alpha.*ap-kpp+(1-delta)*kp,2).^-gam,1,N,1); % requires R2016b
    r=1-delta+bsxfun(@times,(A*alpha)*kp.^(alpha-1),ap);
%     r=1-delta+A*alpha*kp.^(alpha-1).*ap; % requires R2016b
    ucp=reshape(reshape(ucp.*r,M*N,J)*w,M,N);
    uc=mean(A*a.*k.^alpha+(1-delta)*k-kp,2).^-gam;
    y=bsxfun(@rdivide,ucp,uc/(bdamp*beta))+(1-bdamp);
%     y=bdamp*beta*ucp./uc+(1-bdamp); % requires R2016b
    kp=y.*kp;
t5=t5+toc(tmp);
tmp=tic;
    if gpu
        spmd
            kp_ = gpuArray(kp);
            b = B_inv*kp_;
        end
    else
        b = B_inv*kp;
    end
t6=t6+toc(tmp);
    if ~mod(it,disp_iter)
        dkp=mean(abs(1-y(:)));
        tmp=t0; t0=toc; tmp=t0-tmp; gflops=L*M*(2*N+max(mu)-1)/t2*disp_iter/1e9;
        fprintf('%g\t%.1f (%.1f%%)\t%.1f (%.1f%%)\t%.1f (%.1f%%)\t%.1f%%\t%.1f%%\t%.1f%%\t%.1f%%\t%.1f\t%e\n',it,gflops,100*t2/tmp,M*N*8*disp_iter/t1/1024/1024,100*t1/tmp,L*N*8*disp_iter/t3/1024/1024,100*t3/tmp,100*t4/tmp,100*t5/tmp,100*t6/tmp,100*(t1+t2+t3+t4+t5+t6)/tmp,6500/it*t0,dkp)
        t1=0; t2=0; t3=0; t4=0; t5=0; t6=0;
        if dkp<1e-10; break; end
    end
end
time_Smol = toc;
%profile off
fprintf('N = %d\tmu = %d\ttime = %f\n',N,mu(1),time_Smol)
%profile report
if gpu>1
    b{1}=b;
else
    b=gather(b);
end
save(bfile,'b')

%% compute Euler equation errors
tic
T_test=10200; discard=200; Omega=chol(Sigma);
if gssa
    load Smolyak_Anisotropic_JMMV_2014/aT20200N10
    T=10000; x = [[ones(N,T_test); a20200(T+1:T+T_test,1:N)'] [1; nan(2*N-1,1)]];
else
    x=ones(2*N,T_test+1); rng(1); E=exp(randn(T_test,N)*Omega);
end
for t=1:T_test
    x(1:N,t+1)=smolyak(mu,xm,xs,S,x(:,t))*b;
    if ~gssa
        x(N+1:2*N,t+1)=x(N+1:2*N,t).^rho.*E(t,:)';
    end
end
x=x(:,1+discard:end);
T=T_test-discard;
k=x(1:N,1:T); kp=x(1:N,2:T+1); a=x(N+1:2*N,1:T);
ap=reshape(bsxfun(@times,repmat(a.^rho,1,J),e(:)'),T,N,J);
uc=mean(A*a.*k.^alpha+(1-delta)*k-kp,2).^-gam;
if gpu
%     if system(sprintf('nvcc -arch=sm_35 -ptx smolyak_kernel.cu -DD=%d -DM=%d -DN=%d -DSMAX=%d -DMU_MAX=%d',D,M,N,2^max(mu),max(mu))); error('nvcc failed'); end
    kernel = parallel.gpu.CUDAKernel('smolyak_kernel.ptx', 'smolyak_kernel.cu');
    kernel.ThreadBlockSize = 128;
    kernel.GridSize = ceil(T*J/kernel.ThreadBlockSize(1));
    setConstantMemory(kernel,'xm',xm);
    setConstantMemory(kernel,'xs',xs);
    setConstantMemory(kernel,'s',uint8(S-1));
    x=[repmat(kp',1,J); reshape(permute(ap,[2 1 3]),N,T*J)];
    kpp=nan(T*J,N,'gpuArray');
    kpp = gather(feval(kernel, x, kpp, T*J, b));
    kpp=permute(reshape(kpp,N,T,J),[2 1 3]);
else
    kpp=nan(T,N,J);
    for j=1:J
        kpp(:,:,j)=smolyak(mu,xm,xs,S,[kp ap(:,:,j)])*b;
    end
end
% max(max(abs(kpp-kpp_)),[],3)
ucp=repmat(mean(bsxfun(@plus,bsxfun(@times,A*kp.^alpha,ap)-kpp,(1-delta)*kp),2).^-gam,1,N,1);
r=1-delta+bsxfun(@times,(A*alpha)*kp.^(alpha-1),ap);
err=1-bsxfun(@rdivide,reshape(reshape(ucp.*r,T*N,J)*w,T,N),uc/beta); % Unit-free Euler-equation errors
err_mean=log10(mean(abs(err(:))));
err_max=log10(max(abs(err(:))));
time_test = toc;
%% Display the results
format short g
disp(' '); disp('           SMOLYAK OUTPUT:'); disp(' '); 
disp('RUNNING TIME (in seconds):'); disp('');
disp('a) for computing the solution'); 
disp(time_Smol);
disp('b) for implementing the accuracy test'); 
disp(time_test);
disp('APPROXIMATION ERRORS (log10):'); disp(''); 
disp('a) mean Euler-equation error'); 
disp(err_mean)
disp('b) max Euler-equation error'); 
disp(err_max)
exit

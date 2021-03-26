function o = sample(problem, N, opts)
%Input:
% problem - a struct containing the constraints defining the polytope
%
% N - number of indepdent samples
% opts - sampling options
%
%Output:
% o - a structure containing the following properties:
%   samples - a cell of dim x N vectors containing each chain of samples
%   independent_samples - independent samples extracted (according to effective sample size)
%   prepareTime - time to pre-process the input (including find interior
%                 point, remove redundant constraints, reduce dimension etc.)
%   sampleTime - total sampling time in seconds (sum over all workers)
t = tic;

%% Initialize parameters and compiling if needed
if (nargin <= 2)
    opts = default_options();
end
opts.startTime = t;
opts.N = N;

compile_solver(0); compile_solver(opts.simdLen);

%% Presolve
p = rng(opts.seed, 'simdTwister');
opts.seed = p.Seed;

if ischar(opts.logging) || isstring(opts.logging) % logging for Polytope
    fid = fopen(opts.logging, 'a');
    opts.presolve.logFunc = @(tag, msg) fprintf(fid, '%s', msg);
elseif ~isempty(opts.logging)
    opts.presolve.logFunc = opts.logging;
else
    opts.presolve.logFunc = @(tag, msg) 0;
end

polytope = Polytope(problem, opts);
assert(polytope.n > 0, 'The domain consists only a single point.');

if ischar(opts.logging) || isstring(opts.logging)
    fclose(fid);
end

prepareTime = toc(t);

%% Set up workers if nWorkers ~= 1
if opts.nWorkers ~= 1
    % create pool with size nWorkers
    p = gcp('nocreate');
    if isempty(p)
        if opts.nWorkers ~= 0
            p = parpool(opts.nWorkers);
        else
            p = parpool();
        end
    elseif opts.nWorkers ~= 0 && p.NumWorkers ~= opts.nWorkers
        delete(p);
        p = parpool(opts.nWorkers);
    end
    opts.nWorkers = p.NumWorkers;
    
    spmd(opts.nWorkers)
        if opts.profiling
            mpiprofile on
        end
        
        s = Sampler(polytope, opts);
        while s.terminate == 0
            s.step();
        end
        s.finalize();
        workerOutput = s.output;
        
        if opts.profiling
            mpiprofile viewer
        end
    end
    
    o = struct;
    o.workerOutput = cell(opts.nWorkers, 1);
    o.sampleTime = 0;
    for i = 1:opts.nWorkers
        o.workerOutput{i} = workerOutput{i};
        o.sampleTime = o.sampleTime + o.workerOutput{i}.sampleTime;
    end
    
    if ~opts.rawOutput
        o.chains = o.workerOutput{1}.chains;
        for i = 2:opts.nWorkers
            o.chains = [o.chains o.workerOutput{i}.chains];
            o.workerOutput{i}.chains = [];
        end
    end
else
    if opts.profiling
        profile on
    end
    
    s = Sampler(polytope, opts);
    while s.terminate == 0
        s.step();
    end
    s.finalize();
    o = s.output;
    
    if opts.profiling
        profile report
    end
end
o.problem = polytope;
o.opts = opts;

if ~opts.rawOutput
    o.ess = effective_sample_size(o.chains);
    
    y = [];
    for i = 1:numel(o.ess)
        chain_i = o.chains{i};
        ess_i = o.ess{i};
        N_i = size(chain_i,2);
        gap = ceil(N_i/ min(o.ess{i}, [], 'all'));
        for j = 1:size(ess_i,2)
            y_ij = chain_i(:, ceil(opts.nRemoveInitialSamples*gap:gap:N_i));
            y = [y y_ij];
        end
    end
    o.samples = y;
    o.summary = summary(o);
end

o.prepareTime = prepareTime;

function net = cnn_MoE_init_resnet_isqrt_multi_nogating(varargin)
%CNN_IMAGENET_INIT_RESNET  Initialize the ResNet-50 model for ImageNet classification

opts.order = 2;
opts.sectionLen = 2;
opts.averageImage = zeros(3,1) ;
opts.cudnnWorkspaceLimit = 1024*1024*1204 ; % 1GB
opts.branch_num = [];
opts.cat_bn= false ;
opts.agg_drop = false;
opts = vl_argparse(opts, varargin) ;

net = dagnn.DagNN() ;

lastAdded.var = 'input' ;
lastAdded.depth = 3 ;
folder = ['ResNet18-2nd-Ave-SOP'];

    function Conv(name, ksize, depth, varargin)
        % Helper function to add a Convolutional + BatchNorm + ReLU
        % sequence to the network.
        args.relu = true ;
        args.downsample = false ;
        args.bias = false ;
        args = vl_argparse(args, varargin) ;
        if args.downsample, stride = 2 ; else stride = 1 ; end
        if args.bias, pars = {[name '_f'], [name '_b']} ; else pars = {[name '_f']} ; end
        net.addLayer([name  '_conv'], ...
            dagnn.Conv('size', [ksize ksize lastAdded.depth depth], ...
            'stride', stride, ....
            'pad', (ksize - 1) / 2, ...
            'hasBias', args.bias, ...
            'opts', {'cudnnworkspacelimit', opts.cudnnWorkspaceLimit}), ...
            lastAdded.var, ...
            [name '_conv'], ...
            pars) ;
        net.addLayer([name '_bn'], ...
            dagnn.BatchNorm('numChannels', depth), ...
            [name '_conv'], ...
            [name '_bn'], ...
            {[name '_bn_w'], [name '_bn_b'], [name '_bn_m']}) ;
        lastAdded.depth = depth ;
        lastAdded.var = [name '_bn'] ;
        if args.relu
            net.addLayer([name '_relu'] , ...
                dagnn.ReLU(), ...
                lastAdded.var, ...
                [name '_relu']) ;
            lastAdded.var = [name '_relu'] ;
        end
    end

    function Conv_nobn(name, ksize, depth, varargin)
        % Helper function to add a Convolutional + BatchNorm + ReLU
        % sequence to the network.
        args.relu = true ;
        args.downsample = false ;
        args.bias = false ;
        args = vl_argparse(args, varargin) ;
        if args.downsample, stride = 2 ; else stride = 1 ; end
        if args.bias, pars = {[name '_f'], [name '_b']} ; else pars = {[name '_f']} ; end
        net.addLayer([name  '_conv'], ...
            dagnn.Conv('size', [ksize ksize lastAdded.depth depth], ...
            'stride', stride, ....
            'pad', (ksize - 1) / 2, ...
            'hasBias', args.bias, ...
            'opts', {'cudnnworkspacelimit', opts.cudnnWorkspaceLimit}), ...
            lastAdded.var, ...
            [name '_conv'], ...
            pars) ;
        %         net.addLayer([name '_bn'], ...
        %             dagnn.BatchNorm('numChannels', depth), ...
        %             [name '_conv'], ...
        %             [name '_bn'], ...
        %             {[name '_bn_w'], [name '_bn_b'], [name '_bn_m']}) ;
        %         lastAdded.depth = depth ;
        lastAdded.var = [name '_conv'] ;
        if args.relu
            net.addLayer([name '_relu'] , ...
                dagnn.ReLU(), ...
                lastAdded.var, ...
                [name '_relu']) ;
            lastAdded.var = [name '_relu'] ;
        end
    end


% -------------------------------------------------------------------------
% Add input section
% -------------------------------------------------------------------------

Conv('conv1', 3, 16, ...
    'relu', true, ...
    'bias', true, ...
    'downsample', false) ;

% -------------------------------------------------------------------------
% Add intermediate sections
% -------------------------------------------------------------------------

sectionLen = opts.sectionLen ;

for s = 2:5
    % -----------------------------------------------------------------------
    % Add intermediate segments for each section
    for l = 1:sectionLen
        depth = 2^(s+2) ;%s 2:16
        sectionInput = lastAdded ;
        name = sprintf('conv%d_%d', s, l)  ;
        
        % Optional adapter layer
        if l == 1 & s>2
            % %    if l == 1
            Conv([name '_adapt_conv'], 1, 2^(s+2), ...
                'downsample', s <5 | (s == 5 & opts.order == 1), 'relu', false) ;
        end
        sumInput = lastAdded ;
        
        % AB: 3x3, 3x3 ; downsample if first segment in section from
        % section 2 onwards.
        lastAdded = sectionInput ;
        % not downsampling in last block to obtain more feature
        Conv([name 'a'], 3, 2^(s+2), ...
            'downsample', (s == 3 | s==4 |(s == 5 & opts.order == 1)) & l == 1) ;
        Conv([name 'b'], 3, 2^(s+2) ,  'relu', false) ;
        
        % Sum layer
        net.addLayer([name '_sum'] , ...
            dagnn.Sum(), ...
            {sumInput.var, lastAdded.var}, ...
            [name '_sum']) ;
        net.addLayer([name '_relu'] , ...
            dagnn.ReLU(), ...
            [name '_sum'], ...
            name) ;
        lastAdded.var = name ;
    end
end


% -------------------------------------------------------------------------
% Component Module
% -------------------------------------------------------------------------


branch_dim = 128;
last_var =  lastAdded.var;

f_size = 16 ; %2nd order

%branch~experts
lastAdded.depth = 2^(s+2);
IN_EXPERT = lastAdded.var;
mid_dim = 256;
for b = 1:opts.branch_num
    lastAdded.var = IN_EXPERT;
    br_name =  ['branch_' num2str(b)];
    
    Conv([br_name '_a'] , 1, mid_dim ) ;
    
    Conv([br_name '_b'] , 1, branch_dim ) ;
    
    
    br_name = [br_name '_'];
    name = [br_name 'cov_pool'];
    net.addLayer(name , dagnn.OBJ_ConvNet_COV_Pool(),           lastAdded.var,   name) ;
    lastAdded.var = name;
    
    name = [br_name 'cov_trace_norm'];
    name_tr =  [name '_tr'];
    net.addLayer(name , dagnn.OBJ_ConvNet_Cov_TraceNorm(),   lastAdded.var,   {name, name_tr}) ;
    lastAdded.var = name;
    
    name = [br_name 'Cov_Sqrtm'];
    net.addLayer(name , dagnn.OBJ_ConvNet_Cov_Sqrtm( 'coef', 1, 'iterNum', 5),    lastAdded.var,   {name, [name '_Y'], [name, '_Z']}) ;
    lastAdded.var = name;
    lastAdded.depth = lastAdded.depth * (lastAdded.depth + 1) / 2;
    
    name = [br_name 'Cov_ScaleTr'];
    net.addLayer(name , dagnn.OBJ_ConvNet_COV_ScaleTr(),       {lastAdded.var, name_tr},  name) ;
    
    lastAdded.depth = 2^(s+2) ;
end
folder = [folder  '-' num2str(opts.branch_num) 'CMs'];


% -------------------------------------------------------------------------
% Aggregation
% -------------------------------------------------------------------------

for ee = 1:opts.branch_num  %inputs of aggregation layer
    in_{ee} = ['branch_', num2str(ee) , '_Cov_ScaleTr'];
end
net.addLayer( 'branch_out' , ...
    dagnn.branch_nogating_avg('branch' ,opts.branch_num ,...
    'f_size'  , [f_size f_size] ,...
    'hdim' , branch_dim ),...
    in_ , 'branch_out' ) ;
lastAdded.var = 'branch_out' ;
FC_vars = branch_dim * (branch_dim+1)/2  * 1  ;
lastAdded.depth =  branch_dim * (branch_dim+1)/2  * 1  ;

if opts.cat_bn
    name = 'cat_bn';
    net.addLayer(name, ...
        dagnn.BatchNorm('numChannels', lastAdded.depth), ...
        lastAdded.var, ...
        [name '_bn'], ...
        {[name '_bn_w'], [name '_bn_b'], [name '_bn_m']}) ;
    lastAdded.var = [name '_bn'] ;
    
    folder = strcat(folder , '-cat-bn');
end

if opts.agg_drop
    name = ['agg_drop'];
    drop_rate = 0.2;
    net.addLayer(name,dagnn.DropOut('rate',drop_rate),...
        lastAdded.var,name);
    lastAdded.var = name;
    folder = [folder '_drop',num2str(drop_rate)];
end


% -------------------------------------------------------------------------
% Inference Layers
% -------------------------------------------------------------------------

net.addLayer('prediction' , ...
    dagnn.Conv('size', [1 1 FC_vars  1000]), ...
    lastAdded.var, ...
    'prediction', ...
    {'prediction_f', 'prediction_b'}) ;

net.addLayer('loss', ...
    dagnn.Loss('loss', 'softmaxlog') ,...
    {'prediction', 'label'}, ...
    'objective') ;

net.addLayer('top1error', ...
    dagnn.Loss('loss', 'classerror'), ...
    {'prediction', 'label'}, ...
    'top1error') ;

net.addLayer('top5error', ...
    dagnn.Loss('loss', 'topkerror', 'opts', {'topK', 5}), ...
    {'prediction', 'label'}, ...
    'top5error') ;


% -------------------------------------------------------------------------
%                                                           Meta parameters
% -------------------------------------------------------------------------

net.meta.normalization.imageSize = [64 64 3] ;
net.meta.inputSize = [net.meta.normalization.imageSize, 32] ;
net.meta.normalization.averageImage = opts.averageImage ;
net.meta.inputSize = {'input', [net.meta.normalization.imageSize 32]} ;

lr = 1 *[0.1 * ones(1,50), 0.01*ones(1,15), 0.001*ones(1,15) , 1e-4*ones(1,10)] ;
folder = strcat(folder , '-LR_',num2str(lr(1)));

net.meta.trainOpts.learningRate = lr ;
net.meta.trainOpts.numEpochs = numel(lr) ;
net.meta.trainOpts.momentum = 0.9 ;
net.meta.trainOpts.batchSize = 128 * 2;
net.meta.trainOpts.numSubBatches = 4;
net.meta.trainOpts.weightDecay = 0.0001 ;
net.meta.opt = folder ;
% Init parameters randomly
net.initParams() ;


% For uniformity with the other ImageNet networks, t
% the input data is *not* normalized to have unit standard deviation,
% whereas this is enforced by batch normalization deeper down.
% The ImageNet standard deviation (for each of R, G, and B) is about 60, so
% we adjust the weights and learing rate accordingly in the first layer.
%
% This simple change improves performance almost +1% top 1 error.
p = net.getParamIndex('conv1_f') ;
net.params(p).value = net.params(p).value / 60 ;%trick
net.params(p).learningRate = net.params(p).learningRate / 60^2 ;%trick

for l = 1:numel(net.layers)
    if isa(net.layers(l).block, 'dagnn.BatchNorm')
        k = net.getParamIndex(net.layers(l).params{3}) ;
        net.params(k).learningRate = 0.3 ;
        net.params(k).epsilon = 1e-5 ;
    end
end

end

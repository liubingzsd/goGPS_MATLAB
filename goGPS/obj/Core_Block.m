%   CLASS Core Block
% =========================================================================
%
% DESCRIPTION
%   Class to manage goBlock solutions
%
% EXAMPLE
%   go_block = Core_Block();
%
% FOR A LIST OF CONSTANTs and METHODS use doc goGNSS
%
% Note for the future: the class uses the current obs storage of goGPS
% -> switch to objects for rover and master observations is suggested

%--------------------------------------------------------------------------
%               ___ ___ ___
%     __ _ ___ / __| _ | __
%    / _` / _ \ (_ |  _|__ \
%    \__, \___/\___|_| |___/
%    |___/                    v 0.5.1 beta 3
%
%--------------------------------------------------------------------------
%  Copyright (C) 2009-2017 Mirko Reguzzoni, Eugenio Realini
%  Written by:       Gatti Andrea
%  Contributors:     Gatti Andrea, ...
%  A list of all the historical goGPS contributors is in CREDITS.nfo
%--------------------------------------------------------------------------
%
%    This program is free software: you can redistribute it and/or modify
%    it under the terms of the GNU General Public License as published by
%    the Free Software Foundation, either version 3 of the License, or
%    (at your option) any later version.
%
%    This program is distributed in the hope that it will be useful,
%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%    GNU General Public License for more details.
%
%    You should have received a copy of the GNU General Public License
%    along with this program.  If not, see <http://www.gnu.org/licenses/>.
%
%--------------------------------------------------------------------------
% 01100111 01101111 01000111 01010000 01010011
%--------------------------------------------------------------------------

classdef Core_Block < handle

    properties (Constant, Access = private)
        FLAG_CODE_ONLY  = int8(-1);
        FLAG_CODE_PHASE = int8(0);
        FLAG_PHASE_ONLY = int8(1);
    end
    
    properties (Access = public)% Public Access
        logger
        state

        % number of position solutions to be estimated
        n_pos = 1
        
        % number of position solutions to be estimated (high rate)
        n_pos_hr = 1
        
        % solution rate used for the high rate solution
        s_rate = 86400;
        
        % flag to spacify the tipe of solution code only (-1) - code/phase (0) - phase only (1)
        sol_type = Core_Block.FLAG_PHASE_ONLY

        % total number of observations that can be used
        n_obs_tot = 0

        % number of valid epochs used in goBlock
        n_epoch = 0
        
        % max number of valid epochs used in goBlock
        n_tot_epoch = 0
        
        % reference time
        time_diff

        % indexes of empty observations
        empty_epoch = [] 
        
        % matrices to keep track of the satellite configuration changes (to fill in the proper ambiguity slots)
        sat_pr_track    % satellite configuration matrix for code observations
        sat_ph_track    % satellite configuration matrix for phase observations
        pivot_track     % satellite configuration matrix for pivot tracking

        obs_track       % matrix to keep track of the obs -> epoch; PRN; flag code/phase;

        amb_prn_track   % store the prn of each ambiguity
        ref_arc         % arcs used to stabilize the solution (the system is rank deficient)
        col_ok          % columns of the design matrix to be used for the LS

        % LS variable
        A   % LS Design matrix
        Q   % LS Cofactor matrix
        y0  % LS Observations array
        b   % LS known array

        % Results
        pos0          % a-priori position
        pos           % estimated position
        pos_cov       % estimated covariance matrix of the positions
        is_fixed = 0  % 0 => float 1 => fix 2 => fix_hr

        x_float       % estimated parameter s(float solution)
        x_fix         % estimated parameters (fix solution)
        amb_fix       % ambiguities as fixed by lambda
        amb_fix_full  % full set of ambiguities
        G             % transformation matrix SD -> DD
        pos_cov_fix   % Covariance matrix of the fixed positions
        x_hr          % estimated parameters (high_rate)
        Cxx           % Covariance matrix of the parameters
        s02   % estimated variance
        v_hat         % residuals of the obbservarions

        phase_res     % phase residuals ([n_obs x n_amb x 2]);  first slice value, second slice weight
        id_track      % id in the design matrix of the observations in phase_res
    end
    
    % ==================================================================================================================================================
    %  CREATOR
    % ==================================================================================================================================================
    
    methods (Static)
        function this = Core_Block(n_epoch, n_pr_obs, n_ph_obs)
            % Core object creator initialize the structures needed for the computation:
            % EXAMPLE: go_block = Core_Block(n_epoch, n_pr_obs, n_ph_obs)
            
            this.logger = Logger.getInstance();
            this.state = Go_State.getCurrentSettings();

            % number of position solutions to be estimated
            this.n_pos = 1;
            this.n_pos_hr = 1;

            this.n_epoch = n_epoch;
            this.n_tot_epoch = n_epoch;
            this.time_diff = [];
            
            n_sat = this.state.cc.getNumSat();
            % matrices to keep track of the satellite configuration changes (to fill in the proper ambiguity slots)
            this.sat_pr_track = int8(zeros(n_sat, n_epoch));
            this.sat_ph_track = int8(zeros(n_sat, n_epoch));
            this.pivot_track = uint8(zeros(n_epoch, 1));

            % total number of observations (for matrix initialization)
            % (some satellites observations will be discarded -> this is the max size)
            if (this.state.isModePh())
                % n_obs_tot = n_pr_obs + n_ph_obs; % to use code and phase
                this.n_obs_tot = n_ph_obs;              % to only use phase
            else
                this.n_obs_tot = n_pr_obs;
            end

            this.obs_track = NaN(this.n_obs_tot, 3); % epoch; PRN; flag code/phase
            this.empty_epoch = [];

            % init LS variables
            this.y0 = NaN(this.n_obs_tot, 1);
            this.b  = NaN(this.n_obs_tot, 1);
            if (this.state.isModeSA)
                this.A = spalloc(this.n_obs_tot, this.n_pos * 3 + this.n_obs_tot, round(2.5 * this.n_obs_tot));
            else
                this.A = sparse(this.n_obs_tot, this.n_pos * 3);
            end
            this.Q  = sparse(this.n_obs_tot, this.n_obs_tot, 10 * this.n_obs_tot);
        end
    end

    % ==================================================================================================================================================
    %  PROCESSING FUNCTIONS goBlock
    % ==================================================================================================================================================

    methods % Public Access
        function prepare (this, ...
                    time_diff,  ...
                    pos_r, pos_m,  ...
                    pr1_r, pr1_m, pr2_r, pr2_m, ...
                    ph1_r, ph1_m, ph2_r, ph2_m,  ...
                    snr_r, snr_m,  ...
                    eph, sp3, iono, lambda, ant_pcv)

            % Fill the matrices of the LS system, this is necessary to get a solution
            %
            % SYNTAX:
            %   prepare(this, time_diff, pos_r, pos_m, pr1_r, pr1_m, pr2_r, pr2_m, ph1_r, ph1_m, ph2_r, ph2_m, snr_r, snr_m, eph, sp3, iono, lambda, ant_pcv)
            %
            % INPUT:
            %   time_diff  GPS reception time
            %   pos_r      ROVER approximate position
            %   pos_m      MASTER position
            %   pr1_r      ROVER code observations (L1 carrier)
            %   pr1_m      MASTER code observations (L1 carrier)
            %   pr2_r      ROVER code observations (L2 carrier)
            %   pr2_m      MASTER code observations (L2 carrier)
            %   ph1_r      ROVER phase observations (L1 carrier)
            %   ph1_m      MASTER phase observations (L1 carrier)
            %   ph2_r      ROVER phase observations (L2 carrier)
            %   ph2_m      MASTER phase observations (L2 carrier)
            %   snr_r      ROVER-SATELLITE signal-to-noise ratio
            %   snr_m      MASTER-SATELLITE signal-to-noise ratio
            %   eph        satellite ephemeris
            %   sp3        structure containing precise ephemeris and clock
            %   iono       ionosphere parameters
            %   lambda     wavelength matrix (depending on the enabled constellations)
            %   phase      L1 carrier (phase=1), L2 carrier (phase=2)
            %   ant_pcv antenna phase center variation
            %
            % INTERNAL INPUT:
            %   state
            %
            % INTERNAL OUTOUT (properties whos values are changed):
            %   logger, pos, pos0, pos_cov, is_fixed, x_float, x_fix, x_hr, Cxx, s02, v_hat, 
            %   sat_pr_track, sat_ph_track, obs_track
            %   y0, b, A, Q
            %
            % CALL:
            %   oneEpochLS
            %   addAmbiguities
            %
            % EXAMPLE:
            %   go_block = Core_Block(numel(time_GPS), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            %   go_block.prepare(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV);

            this.logger.addMarkedMessage('Preparing goBlock system');

            this.time_diff = time_diff; % reference time
            this.pos = [];          % estimated parameters
            this.pos0 = pos_r;      % a-priori position
            this.pos_cov = [];      % estimated parameters
            this.is_fixed = 0;      % flag is fixed

            this.x_float = [];      % estimated float parameters
            this.x_fix = [];        % estimated parameters (fix solution)
            this.x_hr = [];      % estimated parameters (fix solution + float)
            this.Cxx = [];          % Covariance matrix of the parameters
            this.s02 = [];  % estimated variance
            this.v_hat = [];        % residuals of the obbservarions;

            % up to now GPS only is available for goBLock
            frequencies = find(this.state.cc.getGPS().flag_f);

            % get wait bar instance
            w_bar = Go_Wait_Bar.getInstance();

            % variable name change for readability reasons
            n_sat = this.state.cc.getNumSat();

            % init epoch counter
            epoch_track = 0;
            epoch_ok = 1 : length(time_diff);
            this.pivot_track = uint8(zeros(length(time_diff), 1));

            % goGPS waiting bar
            w_bar.setBarLen(length(time_diff));
            w_bar.createNewBar('Building the design matrix...');

            % init loop
            for t = epoch_ok
                eph_t = rt_find_eph (eph, time_diff(t), n_sat);

                [y0_epo, A_epo, b_epo, Q_epo, this.sat_pr_track(:, t), this.sat_ph_track(:, t), pivot] = this.oneEpochLS (time_diff(t), pos_r, pos_m(:,t), pr1_r(:,t), pr1_m(:,t), pr2_r(:,t), pr2_m(:,t), ph1_r(:,t), ph1_m(:,t), ph2_r(:,t), ph2_m(:,t), snr_r(:,t), snr_m(:,t), eph_t, sp3, iono, lambda, frequencies(1), ant_pcv);

                if (pivot > 0)
                    n_obs = length(y0_epo);

                    idx = epoch_track + (1 : n_obs)';

                    this.y0( idx) = y0_epo;
                    this.b ( idx) =  b_epo;
                    this.A ( idx, 1:3) = A_epo;
                    this.Q ( idx, idx) = Q_epo;

                    this.obs_track(idx, 3) = 1;
                    this.obs_track(idx, 2) = setdiff(find(this.sat_ph_track(:,t)), pivot);
                    this.obs_track(idx, 1) = t;

                    this.pivot_track(t) = pivot;

                    epoch_track = epoch_track + n_obs;
                else
                    this.empty_epoch = [this.empty_epoch; t];
                end
                w_bar.goTime(t);
            end

            % cut the empty epochs
            this.sat_pr_track(:,this.empty_epoch) = [];
            this.sat_ph_track(:,this.empty_epoch) = [];
            this.pivot_track(this.empty_epoch) = [];

            this.n_epoch = length(this.pivot_track);

            % cut the unused lines
            id_ko = (epoch_track + 1 : size(this.A,1))';
            this.n_obs_tot = epoch_track;
            this.y0(id_ko) = [];
            this.b(id_ko) = [];
            this.A(id_ko, :) = [];
            this.Q(:, id_ko) = [];
            this.Q(id_ko, :) = [];
            this.obs_track(id_ko,:) = [];
            w_bar.close();
            
            % Add to the Design matric the columns relative to the ambbiguities
            this.addAmbiguities (lambda);
        end

        function [pos, pos_cov] = solveFloat (this, full_slip_split)
            % Compute a first float solution
            %
            % METHODS CALL REQUIREMENTS:
            %  -> prepare
            %
            % SYNTAX:
            %   [pos, pos_cov] = this.solveFloat(this)
            %
            % INTERNAL INPUT:
            %   A, y0, b, Q, obs_track, amb_num, amb_prn_track, state, logger
            %
            % OUTPUT:
            %   pos     coordinates of the estimated positions
            %   pos_cov         covariance of the estimated positions
            %
            % INTERNAL OUTOUT (properties whos values are changed):
            %   x_float, Cxx, s02, v_hat, pos, pos_cov, is_fixed
            %   y0,  b, A, Q
            %   obs_track, amb_prn_track, n_epoch
            %
            % EXAMPLE:
            %   go_block = Core_Block(numel(time_GPS), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            %   go_block.prepare(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV);
            %   go_block.solveFloat()

            this.logger.addMarkedMessage('Compute a float solution');

            if nargin == 1
                full_slip_split = this.state.getFullSlipSplit();
            end
            flag_outlier = this.state.isOutlierRejectionOn();
            % flag_outlier = false;
            
            % Let's first clean short observations arcs
            [this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track] = this.remShortArc(this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, this.state.getMinArc());
            
            % A block is an interval of continuous phase observations
            [this.col_ok, this.ref_arc, blk_cols, blk_rows] = this.getBlockProperties();
            
            % To disable full slip split put full_slip_split = false;
            if ~full_slip_split
                blk_cols = true(size(blk_cols, 1), 1);
                blk_rows = true(size(blk_rows, 1), 1);
            end
            n_block = size(blk_cols, 2);
            
            this.logger.addMarkedMessage(sprintf('Independent blocks found: %d', n_block));
            pivot_change = find(abs(diff(int8(this.pivot_track)))>0);
            row_id  = 1;
            col_id  = 3 + 1;
            this.ref_arc = zeros(n_block,1);
            bad_blocks = [];
            
            for i = 1 : n_block
                this.logger.addMessage(sprintf('      Processing block %d/%d -------------------------------', i, n_block));
                
                % Extract a subset of the LS system
                y0 = this.y0(blk_rows(:, i));
                b = this.b(blk_rows(:, i));
                A = this.A(blk_rows(:, i), blk_cols(:, i));
                Q = this.Q(blk_rows(:, i), blk_rows(:, i));
                obs_track = this.obs_track(blk_rows(:, i),:);
                epoch_offset = obs_track(1,1) - 1;
                pivot_change = pivot_change - epoch_offset;
                obs_track(:,1) = obs_track(:,1) - epoch_offset;
                amb_prn_track = this.amb_prn_track(blk_cols(this.n_pos * 3 + 1 : end, i));
                
                % Get the arc with higher quality
                [col_ok, ref_arc] = this.getBestRefArc(y0, b, A, Q);
            
                if this.state.isPreCleaningOn()
                    this.logger.addMessage('       - try to improve observations (risky...check the results!!!)');
                    % Try to correct cycle slips / discontinuities in the observations and increase spike variance
                    % WARNING: risky operation, do it with consciousness, check the results against disabled pre-cleaning
                    %          this feature can be used when the phase residuals show unresolved anbiguities
                    [y0, Q] = this.preCorrectObsIntAmb(y0, b, A, col_ok, Q, this.n_pos, obs_track, pivot_change); % Try to correct integer ambiguities slips (maybe missed cycle slips)
                end
                
                this.logger.addMessage('       - first estimation');
                
                % computing a first solution with float ambiguities
                [x_float, Cxx, s02, v_hat] = this.solveLS(y0, b, A, col_ok, Q);
                
                this.logger.addMessage('       - improve solution by outlier underweight');
                % Improve solution by iterative increase of bad observations variance
                [x_float, Cxx, s02, v_hat, Q_tmp] = this.improveFloatSolution(y0, b, A, col_ok, Q, v_hat, obs_track);
                
                % Compute phase residuals
                [phase_res, id_track] = this.computePhRes( v_hat, A, Q, obs_track, 1, size(A,1));
                n_clean = this.state.getBlockPostCleaningLoops();
                
                % Try to fix missing cycle slips
                [~, Cxx, y0, Q_tmp] = this.loopCorrector(y0, b, A, col_ok, Q, obs_track, amb_prn_track, phase_res, id_track, n_clean);
                
                if this.state.isBlockForceStabilizationOn()
                    % If the system is unstable remove the arcs that are making it so
                    [A, col_ok, ref_arc, y0, b, Q, obs_track, amb_prn_track] = remUnstableArcs(A, col_ok, ref_arc, y0, b, Q, obs_track, amb_prn_track, Cxx);
                end
                
                if (size(A,2) > 3 + 2)
                    if (flag_outlier)
                        % Delete bad observations and restore variances
                        this.logger.addMessage('       - reject outliers');
                        [~, ~, ~, ~, y0,  b, A, col_ok, Q, obs_track, amb_prn_track] = this.cleanFloatSolution(y0, b, A, col_ok, Q, v_hat, obs_track, amb_prn_track, 9);
                        [~, ~, ~, ~, y0,  b, A, ~, Q, obs_track, amb_prn_track] = this.remSolitaryObs(y0, b, A, col_ok, Q, obs_track, amb_prn_track, round(this.state.getMinArc()/2));
                        [col_ok, ref_arc] = this.getBestRefArc(y0, b, A, Q);
                        [~, Cxx, ~, ~] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
                        
                        if this.state.isBlockForceStabilizationOn()
                            % If the system is unstable remove the arcs that are making it so
                            [A, ~, ref_arc, y0, b, Q, obs_track, amb_prn_track] = remUnstableArcs(A, col_ok, ref_arc, y0, b, Q, obs_track, amb_prn_track, Cxx);
                        end
                    else
                        Q = Q_tmp;
                    end
                end
                
                if (size(A,2) < 3 + 2)
                    % If the system is completely unstable
                    this.logger.addMessage('         [ WW ] system still unstable, try to use it as it is!!!\n                (it might be stabilized by the unified solution)');
                    bad_blocks = [bad_blocks; i]; %#ok<AGROW>
                    y0 = this.y0(blk_rows(:, i));
                    b = this.b(blk_rows(:, i));
                    A = this.A(blk_rows(:, i), blk_cols(:, i));
                    Q = this.Q(blk_rows(:, i), blk_rows(:, i));
                    obs_track = this.obs_track(blk_rows(:, i),:);
                    epoch_offset = obs_track(1,1) - 1;
                    pivot_change = pivot_change - epoch_offset;
                    obs_track(:,1) = obs_track(:,1) - epoch_offset;
                    amb_prn_track = this.amb_prn_track(blk_cols(this.n_pos * 3 + 1 : end, i));
                    
                    [~, ref_arc] = this.getBestRefArc(y0, b, A, Q);
                end
                % reassemble the system
                % id on the obj matrix
                row_id_last = row_id + numel(y0) - 1;
                full_row_id = row_id : row_id_last;
                
                col_id_last = col_id + size(A, 2) - 3 - 1;
                full_col_id = (col_id : col_id_last);
                
                % find the columns that are still used
                this.ref_arc(i) = ref_arc + col_id - 1 - 3;
                this.y0(full_row_id) = y0;
                this.b(full_row_id) = b;
                this.A(full_row_id, :) = 0;
                this.A(full_row_id, [(1 : 3) full_col_id]) = A;
                this.Q(full_row_id, :) = 0;
                this.Q(:, full_row_id) = 0;
                this.Q(full_row_id,full_row_id) = Q;
                obs_track(:,1) = obs_track(:,1) + epoch_offset;
                this.obs_track(full_row_id, :) = obs_track;
                this.amb_prn_track(full_col_id - 3) = amb_prn_track;
                row_id = row_id_last + 1;
                col_id = col_id_last + 1;
            end

            % remove unecessary rows (observations removed as outliers)
            this.y0(row_id_last + 1 : end) = [];
            this.b(row_id_last + 1 : end) = [];
            this.A(row_id_last + 1 : end, :) = [];
            this.Q(row_id_last + 1 : end,:) = [];
            this.Q(:, row_id_last + 1 : end) = [];
            this.obs_track(row_id_last + 1 : end, :) = [];
            
            this.amb_prn_track(col_id_last + 1 - 3 : end) = [];
            this.A(:, col_id_last +1 : end) = [];
            [this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track] = this.remShortArc(this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, this.state.getMinArc());
            this.col_ok = setdiff(1:size(this.A, 2), this.ref_arc + 3);
            
            if full_slip_split
                [~, ~, blk_cols, ~] = this.getBlockProperties();
                if ~isempty(bad_blocks)
                    [this.col_ok, this.ref_arc] = this.getBestBlockRefArc(this.y0, this.b, this.A, this.Q, this.ref_arc, [], bad_blocks, blk_cols);
                end
            end
            
            this.logger.addMarkedMessage('Compute the final float solution -------------------');
            [this.x_float, this.Cxx, this.s02, this.v_hat] = fast_least_squares_solver(this.y0, this.b, this.A(:, this.col_ok), this.Q);

            this.logger.addMessage('       - improve solution by outlier underweight');
            [this.x_float, this.Cxx, this.s02, this.v_hat, Q_tmp] = this.improveFloatSolution(this.y0, this.b, this.A, this.col_ok, this.Q, this.v_hat, this.obs_track);
            [this.phase_res, this.id_track] = this.computePhRes();
            
            if full_slip_split
            % Refining final solution if it have been computed in blocks
                                
                [this.x_float, this.Cxx, this.y0, Q_tmp, this.s02, this.v_hat] = this.loopCorrector(this.y0, this.b, this.A, this.col_ok, this.Q, this.obs_track, this.amb_prn_track, this.phase_res, this.id_track, n_clean);
                [this.phase_res, this.id_track] = this.computePhRes();
                
                % If the system is unstable try to change the reference arc
                bad_col = find(abs(median(this.phase_res(:,:,1),'omitnan')) > 1) + 3;
                if ~isempty(bad_col)
                    [this.col_ok, this.ref_arc, bad_blocks] = this.getBestBlockRefArc(this.y0, this.b, this.A, this.Q, this.ref_arc, bad_col - 3, [], blk_cols);
                    if ~isempty(bad_blocks)
                        [this.x_float, this.Cxx, this.s02, this.v_hat, ~] = this.improveFloatSolution(this.y0, this.b, this.A, this.col_ok, this.Q, this.v_hat, this.obs_track);
                        [this.phase_res, this.id_track] = this.computePhRes();
                        bad_col = find(abs(median(this.phase_res(:,:,1),'omitnan')) > 1) + 3;
                        [this.x_float, this.Cxx, this.y0, Q_tmp, this.s02, this.v_hat] = this.loopCorrector(this.y0, this.b, this.A, this.col_ok, this.Q, this.obs_track, this.amb_prn_track, this.phase_res, this.id_track, n_clean);
                        [this.phase_res, this.id_track] = this.computePhRes();
                    end
                end
                
                if this.state.isBlockForceStabilizationOn()
                    % If the system is still unstable remove the with median high residuals
                    while ~isempty(bad_col)
                        
                        while ~isempty(bad_col)
                            [~, ~, blk_cols, ~] = this.getBlockProperties();
                            blk_cols(1 : 3, :) = 0;
                            unstable_block = find(sum([blk_cols; -blk_cols(bad_col,:)]) < 3);
                            if ~isempty(unstable_block)
                                this.logger.addWarning(sprintf('One or more block have been found unstable, removing block %s', sprintf('%d ', unstable_block)));
                                bad_col = union(bad_col, find(blk_cols(:, unstable_block)));
                                this.ref_arc(unstable_block) = [];
                            end
                            
                            for a = 1 : numel(this.ref_arc); this.ref_arc(a) = this.ref_arc(a) - sum(bad_col < this.ref_arc(a) + 3); end
                            this.col_ok = setdiff(1 : size(this.A, 2), this.ref_arc + 3);
                            
                            this.logger.addMessage(sprintf('         [ WW ] System unstable, removing arcs: %s PRNs: %s', sprintf('%d ', bad_col - 3), sprintf('%d ', this.amb_prn_track(bad_col - 3))));
                            [this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track] = this.remArcCol(this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, bad_col);
                            [this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, bad_col] = this.remShortArc(this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, this.state.getMinArc());
                        end
                        this.ref_arc = setdiff(this.ref_arc, bad_col - 3);
                        for a = 1 : numel(this.ref_arc); this.ref_arc(a) = this.ref_arc(a) - sum(bad_col < this.ref_arc(a) + 3); end
                        this.col_ok = setdiff(1 : size(this.A, 2), this.ref_arc + 3);
                        [this.x_float, this.Cxx, this.s02, this.v_hat] = fast_least_squares_solver(this.y0, this.b, this.A(:, this.col_ok), this.Q);
                        [this.x_float, this.Cxx, this.s02, this.v_hat, Q_tmp] = this.improveFloatSolution(this.y0, this.b, this.A, this.col_ok, this.Q, this.v_hat, this.obs_track);
                        [this.phase_res, this.id_track] = this.computePhRes();
                        amb_var = zeros(size(this.Cxx,1) + numel(this.ref_arc)); amb_var(this.col_ok) = diag(this.Cxx);
                        bad_col = find(abs(median(this.phase_res(:,:,1),'omitnan')) > 1) + 3;
                    end
                end
                
                % if flag_outlier
                %     this.logger.addMessage('       - reject outliers');
                %     [this.phase_res, this.id_track] = this.computePhRes();
                %     N_inv = [];
                %     subset_out = serialize(this.id_track(abs(this.phase_res(:,:,1)) > 0.05));
                %     [x_k, s2_k, v_hat_k, Cxx_k, N_inv] = ELOBO(this.A(:, this.col_ok), this.Q, this.y0, this.b, N_inv, this.v_hat, this.x_float, this.s02, subset_out);
                %     subset_in = serialize(this.id_track(abs(this.phase_res(:,:,1)) < 10 * this.state.getMaxPhaseErrThr));
                %     this.y0 = this.y0(subset_in);
                %     this.b = this.b(subset_in);
                %     this.A = this.A(subset_in, :);
                %     Q_tmp = Q_tmp(subset_in, subset_in);
                %     this.Q = this.Q(subset_in, subset_in);
                %     this.obs_track = this.obs_track(subset_in, :);
                %     [this.x_float, this.Cxx, this.s02, this.v_hat, Q_tmp] = this.improveFloatSolution(this.y0, this.b, this.A, this.col_ok, Q_tmp, [], this.obs_track);
                %     [this.phase_res, this.id_track] = this.computePhRes();
                % end
                
                if this.state.isBlockForceStabilizationOn()
                    % If the system is unstable remove the arcs that are making it so
                    amb_var = zeros(size(this.Cxx,1) + numel(this.ref_arc), 1); amb_var(this.col_ok) = diag(this.Cxx);
                    amb_var(amb_var < 0) = 100; % negative variances means bad arcs
                    bad_col = find(amb_var(4:end) > 1) + 3;
                    
                    while ~isempty(bad_col)
                        [~, ~, blk_cols, ~] = this.getBlockProperties();
                        blk_cols(1 : 3, :) = 0;
                        unstable_block = find(sum([blk_cols; -blk_cols(bad_col,:)]) < 3);
                        if ~isempty(unstable_block)
                            this.logger.addWarning(sprintf('One or more block have been found unstable, removing block %s', sprintf('%d ', unstable_block)));
                            bad_col = union(bad_col, find(blk_cols(:, unstable_block)));
                            this.ref_arc(unstable_block) = [];
                        end
                        
                        for a = 1 : numel(this.ref_arc); this.ref_arc(a) = this.ref_arc(a) - sum(bad_col < this.ref_arc(a) + 3); end
                        this.col_ok = setdiff(1 : size(this.A, 2), this.ref_arc + 3);
                        
                        this.logger.addMessage(sprintf('         [ WW ] System unstable, removing arcs: %s\n                                          PRNs: %s', sprintf('%d ', bad_col - 3), sprintf('%d ', this.amb_prn_track(bad_col - 3))));
                        [this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track] = this.remArcCol(this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, bad_col);
                        [this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, bad_col] = this.remShortArc(this.A, this.y0, this.b, this.Q, this.obs_track, this.amb_prn_track, this.state.getMinArc());
                        this.ref_arc = setdiff(this.ref_arc, bad_col - 3);
                        for a = 1 : numel(this.ref_arc); this.ref_arc(a) = this.ref_arc(a) - sum(bad_col < this.ref_arc(a) + 3); end
                        this.col_ok = setdiff(1 : size(this.A, 2), this.ref_arc + 3);
                        [this.x_float, this.Cxx, this.s02, this.v_hat] = fast_least_squares_solver(this.y0, this.b, this.A(:, this.col_ok), this.Q);
                        [this.x_float, this.Cxx, this.s02, this.v_hat, Q_tmp] = this.improveFloatSolution(this.y0, this.b, this.A, this.col_ok, this.Q, this.v_hat, this.obs_track);
                        
                        [this.phase_res, this.id_track] = this.computePhRes();
                        [this.x_float, this.Cxx, this.y0, Q_tmp, this.s02, this.v_hat] = this.loopCorrector(this.y0, this.b, this.A, this.col_ok, this.Q, this.obs_track, this.amb_prn_track, this.phase_res, this.id_track, n_clean);
                        [this.phase_res, this.id_track] = this.computePhRes();
                        
                        amb_var = zeros(size(this.Cxx,1) + numel(this.ref_arc), 1); amb_var(this.col_ok) = diag(this.Cxx);
                        amb_var(amb_var < 0) = 100; % negative variances means bad arcs
                        bad_col = find(amb_var(4:end) > 1) + 3;
                        % amb_var = zeros(size(this.Cxx,1) + numel(ref_arc)); amb_var(this.col_ok) = diag(this.Cxx);
                        % bad_col = find((amb_var(4:end) > 10) | (amb_var(4:end) > mean(amb_var(col_ok(4 : end))) + 10 * std(amb_var(col_ok(4 : end))))) + 3;
                    end
                end
            end
            
            this.Q = Q_tmp;
        
            % Compute phase residuals
            %[this.phase_res, this.id_track] = this.computePhRes();
            %[this.x_float, this.Cxx, this.y0, this.Q, this.s02, this.v_hat] = this.loopCorrector(this.y0, this.b, this.A, this.col_ok, this.Q, this.obs_track, this.amb_prn_track, this.phase_res, this.id_track, n_clean);
            [this.phase_res, this.id_track] = this.computePhRes();

            % show residuals
            %close all; this.plotPhRes();

            % extract estimated position
            this.logger.addMarkedMessage('Float solution computed, rover positions corrections:');
            d_pos = reshape(this.x_float(1:this.n_pos * 3), 3, this.n_pos);
            pos = repmat(this.pos0(:), 1, this.n_pos) + d_pos;
            this.logger.addMessage(sprintf('       East      %12.4f   %+8.4f m\n       North     %12.4f   %+8.4f m\n       Up        %12.4f   %+8.4f m\n', [this.getENU(pos)' this.getDeltaENU(pos)']'));
            pos_cov = full(this.Cxx(1:this.n_pos * 3, 1:this.n_pos * 3));
            this.is_fixed = 0;
            this.pos = pos;
            this.pos_cov = pos_cov;
        end
        
        function [pos, pos_cov, amb_fix, amb_cov, amb_fix_full, ref_arc, G] = solveFix (this)
            % Compute a fixed solution using LAMBDA, and the the internal object properties
            %
            % METHODS CALL REQUIREMENTS:
            %   prepare -> addAmbiguities -> solveFloat
            %
            % SYNTAX:
            %   [pos, pos_cov, amb_fix, amb_cov, amb_fix_full, ref_arc] = this.solveFix()
            %
            % INTERNAL INPUT:
            %   x_float, Cxx, A, n_pos, state, logger
            %
            % OUTPUT:
            %   pos             coordinates of the estimated positions
            %   pos_cov         covariance of the estimated positions
            %   amb_fix         ambiguities as estimated by lambda (n-1 w.r.t. float solution)
            %   amb_cov         ambiguities error covariance matrix
            %   amb_fix_full ambbiguities as converted from fix to float -> to be imported as pseudo observations of the float solution
            %   ref_arc         arc used as reference in the fix solution (it's the arc that create a bias in the solution)
            %   G               transformation matrix -> float -> fix
            %
            % INTERNAL OUTOUT (properties whos values are changed):
            %   x_fix, Cxx, pos, pos_cov, is_fixed
            %
            % EXAMPLE:
            %   go_block = Core_Block(numel(time_GPS), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            %   go_block.prepare(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV);
            %   go_block.addAmbiguities(lambda)
            %   go_block.solveFloat()
            %   go_block.solveFix()
            %
            % CONCRETE IMPLEMENTATION IN:
            %   solveFixPar
            %
            
            this.logger.addMarkedMessage('Compute ambiguity fix through LAMBDA');

            [d_pos, pos_cov, is_fixed, amb_fix, amb_cov, amb_fix_full, ref_arc, G] = this.solveFixPar (this.x_float, this.Cxx, size(this.A, 2) - 3 - numel(this.ref_arc));
            this.is_fixed = is_fixed;

            pos = this.pos;
            if (is_fixed)
                % extract estimated position
                this.logger.addMarkedMessage('Fixed solution computed, rover positions corrections:');
                pos = repmat(this.pos0(:), 1, this.n_pos) + repmat(d_pos(:), 1, this.n_pos);
                this.logger.addMessage(sprintf('       East      %12.4f   %+8.4f m\n       North     %12.4f   %+8.4f m\n       Up        %12.4f   %+8.4f m\n', [this.getENU(pos)' this.getDeltaENU(pos)']'));
                this.pos = pos;
                this.pos_cov = pos_cov;
                this.pos_cov_fix = pos_cov;
                this.x_fix = [d_pos; amb_fix_full];
            end

        end
        
        function [pos] = solve(this, s_rate, full_slip_split)
            % Solve Float -> Fix -> try an estimation of positions at a different rate
            %
            % METHODS CALL REQUIREMENTS:
            %  -> prepare
            %
            % SYNTAX:
            %   [pos, pos_cov, v_hat] = this.solve(this)
            %
            % INTERNAL INPUT:
            %   full object properties
            %
            % OUTPUT:
            %   pos     coordinates of the estimated positions
            %   pos_cov         covariance of the estimated positions
            %
            % INTERNAL OUTOUT (properties whos values are changed):
            %   x_float, Cxx, s02, v_hat, pos, pos_cov, is_fixed
            %   y0,  b, A, Q
            %   obs_track, amb_prn_track, n_epoch
            %
            % EXAMPLE:
            %   go_block = Core_Block(numel(time_GPS), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            %   go_block.prepare(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV);
            %   [pos, pos_cov] = go_block.solve();

            if (nargin == 1) || isempty(s_rate)
                s_rate = this.time_diff(end);
            end
            if nargin < 3
                full_slip_split = true;
            end
            
            % Compute the best float solution
            this.solveFloat(full_slip_split);
            
            if (this.state.flag_iar)
                % Solve Fix -> get a valid estimation of the integer ambiguities
                [~, ~, this.amb_fix, ~, this.amb_fix_full, ~, this.G] = this.solveFix();
                %% HR prediction
                if nargin == 2 % if s_rate is defined
                    this.solveHighRate(s_rate);
                end
            end
            pos = this.pos;
        end
                
        function [pos, pos_cov, v_hat] = solveHighRate(this, s_rate, use_float)
            % Solve Float -> Fix -> try an estimation of positions at a different rate
            %
            % METHODS CALL REQUIREMENTS:
            %  -> prepare
            %
            % SYNTAX:
            %   [pos, pos_cov, v_hat] = this.solve(this)
            %
            % INTERNAL INPUT:
            %   full object properties
            %
            % OUTPUT:
            %   pos     coordinates of the estimated positions
            %   pos_cov         covariance of the estimated positions
            %
            % INTERNAL OUTOUT (properties whos values are changed):
            %   x_float, Cxx, s02, v_hat, pos, pos_cov, is_fixed
            %   y0,  b, A, Q
            %   obs_track, amb_prn_track, n_epoch
            %
            % EXAMPLE:
            %   go_block = Core_Block(numel(time_GPS), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            %   go_block.prepare(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV);
            %   [pos, pos_cov] = go_block.solve();
            
            % HR prediction
            narginchk(2,3);
            if nargin == 2
                use_float = false;
            end
            
            if s_rate > 0
                this.logger.addMarkedMessage(sprintf('Computing high rate solution @%d seconds', s_rate));
                
                % Find ids of observations involved in a certain time span (solution rate)
                
                s_time_lim = unique([this.time_diff(1) : s_rate : this.time_diff(end) this.time_diff(end)]');
                time_track = this.time_diff(this.obs_track(:,1));
                s_time_lim = [s_time_lim(1 : end-1) s_time_lim(2 : end)];
                block_id_lim = zeros(size(s_time_lim));
                n_pos_hr = size(s_time_lim, 1);  % new number of positions
                for l = 1 : n_pos_hr
                    block_id_lim(l, 1) = find(time_track >= s_time_lim(l, 1), 1, 'first');
                    block_id_lim(l, 2) = find(time_track < s_time_lim(l, 2), 1, 'last');
                end
                block_id_lim(end,2) = size(this.obs_track,1);
                
                % Buid the Design Matrix for the high rate estimation
                n_pos_hr = size(block_id_lim, 1);
                A_hr = sparse(size(this.A, 1), size(this.A, 2) + 3 * (n_pos_hr - this.n_pos));
                for i = 1 : n_pos_hr
                    id = block_id_lim(i,1) : block_id_lim(i,2);
                    A_hr(id, (3 * (i - 1) + 1 : 3 * i)) = this.A(id,1:3);
                end
                i = i + 1;
                A_hr(:,(3 * (i - 1) + 1) : end) = this.A(:, 4 : end);
                
                amb_hr_ok = [(1 : 3 * n_pos_hr) (this.col_ok(3 + 1 : end) + 3 * (n_pos_hr - this.n_pos))];
                % Solve the new system
                [x_float, Cxx, s02, v_hat] = fast_least_squares_solver(this.y0, this.b, A_hr(:, amb_hr_ok), this.Q); %#ok<ASGLU,PROPLC>
                                
                % Transformation matrix for the estimation of a unique position (computed as the mean)
                % T = zeros(size(x_float,1) - (n_pos_hr - this.n_pos) * 3, size(x_float,1));
                % for i = 1 : n_pos_hr
                %     T(1 : 3, (i - 1) * 3 + 1 : i * 3) = eye(3) ./ n_pos_hr;
                % end
                % T(4 : end, n_pos_hr * 3 + 1 : end) = eye(numel(x_float) - 3 * n_pos_hr);
                % x_float_mean_pos = T * x_float;
                % Cxx_mean_pos = T * Cxx * T';
                % [~, ~, ~, this.amb_fix, ~, this.amb_fix_full, ~, G] = this.solveFixPar (x_float_mean_pos, Cxx_mean_pos, size(this.A, 2) - 3 - 1);
                
                if this.is_fixed() && ~use_float
                    % Check for positions that cannot be estimated
                    pos_nan = [];
                    if (sum(isnan(x_float(1 : 3 * n_pos_hr))) > 0)
                        this.logger.addWarning('Some high rate positions have not been estimated!');
                        pos = x_float(1 : 3 * n_pos_hr);
                        pos_nan = isnan(pos);
                        pos_nan(3 * n_pos_hr + 1 : end) = false;
                        x_float(pos_nan) = [];
                        Cxx(:, pos_nan) = [];
                        Cxx(pos_nan, :) = [];
                    end
                    
                    % Fix ambiguities
                    [d_pos, pos_cov] = this.applyFix(x_float,  Cxx, this.amb_fix, this.G);
                    
                    if ~isempty(pos_nan)
                        pos_nan = pos_nan(1 : 3 * n_pos_hr);
                        d_pos_new = nan(3, n_pos_hr, 1);
                        d_pos_new(~pos_nan) = d_pos;
                        d_pos = d_pos_new; clear d_pos_new;
                        pos_cov_new = nan(3 * n_pos_hr, 3* n_pos_hr);
                        pos_cov_new(~pos_nan, ~pos_nan) = pos_cov;
                        pos_cov = pos_cov_new; clear pos_cov_new;
                    end
                    v_hat = this.y0 - (A_hr(:, amb_hr_ok) * [d_pos(:); this.amb_fix_full] + this.b);
                else
                    this.logger.addWarning('The computed high rate solution is NOT fixed (float)!!!')
                    d_pos = reshape(x_float(1 : 3 * n_pos_hr), 3, n_pos_hr);
                    pos_cov = Cxx(1 : 3 * n_pos_hr, 1 : 3 * n_pos_hr);
                end
                
                this.x_hr = [d_pos(:); this.amb_fix_full];
                pos = repmat(this.pos0, 1, n_pos_hr) + d_pos;
                
                this.logger.addMarkedMessage('High Rate solution computed, rover positions corrections (mean HR):');
                this.logger.addMessage(sprintf('       East      %12.4f   %+8.4f m\n       North     %12.4f   %+8.4f m\n       Up        %12.4f   %+8.4f m\n', [mean(this.getENU(pos),1, 'omitnan')' mean(this.getDeltaENU(pos),1, 'omitnan')']'));
                this.is_fixed = this.is_fixed * 2;
                this.n_pos_hr = n_pos_hr;
                this.pos = pos;
                this.pos_cov = pos_cov;
                this.s_rate = s_rate;
            end
        end
        
        function [A, y0, b, Q] = applyFixSuggestion(this, amb_fix_full, amb_cov, ref_arc, A, y0, b, Q, n_pos)
            % Given a set of fixed suggestions build a new LS system adding new pseudo observations
            %
            % SYNTAX:
            %   [A, y0, b, Q] = addFixSuggestion(this, amb_fix_full, amb_cov, ref_arc, A, y0, b, Q, n_pos)
            
            narginchk(4, 9);
            if nargin < 9
                A = this.A;
                y0 = this.y0;
                b = this.b;
                Q = this.Q;
                n_pos = this.n_pos;
            end
            n_amb = numel(amb_fix_full) - 1;
            n_obs = size(A, 1);
            n_est = n_pos;
            
            % Build a Design matrix with LAMBDA fix suggestions
            idx = [1 : ref_arc - 1, ref_arc + 1 : n_amb + 1]; % indexes of the fixed ambiguities returned by lambda
            n_amb = numel(idx);
            A = [A; sparse(n_amb, size(A, 2))];               % A matrix gains n rows, 1 for each fixed ambiguity
            y0 = [y0; round(amb_fix_full(idx))];           % y0 array gains n rows with the values of the fixed ambiguities
            b = [b; zeros(n_amb, 1)];                         % b array gains n rows of zeros
            Q = [[Q sparse(size(Q, 1), n_amb)]; sparse(n_amb, size(Q, 1) + n_amb)]; % Q matrix gains n rows and cols, 1 for each fixed ambiguity
            
            for i = 1 : n_amb
                A(n_obs + i, 3 * n_est + idx(i)) = 1;
            end
            Q(n_obs + (1:n_amb), n_obs +  (1:n_amb)) = amb_cov;
        end

        function [A, y0, b, Q, obs_track, amb_prn_track] = remObs (this, A, y0, b, Q, obs_track, amb_prn_track, rem_obs)
            A(rem_obs,:) = [];
            y0(rem_obs) = [];
            b(rem_obs) = [];
            Q(rem_obs,:) = []; Q(:,rem_obs) = [];
            obs_track(rem_obs,:) = [];
            [A, y0, b, Q, obs_track, amb_prn_track] = this.remShortArc(A, y0, b, Q, obs_track, amb_prn_track, this.state.getMinArc());
            this.getBlockProperties();
        end
    end
    
    % ==================================================================================================================================================
    %  AUXILIARY FUNCTIONS goBlock
    % ==================================================================================================================================================

    methods % Public Access
        function plotPhRes (this, phase_res, id_track, A, amb_prn_track)
            if nargin == 1
                phase_res = this.phase_res;
                id_track = this.id_track;
                A = this.A;
                amb_prn_track = this.amb_prn_track;
            end

            x = (1 : size(phase_res,1));
            h = figure();
            for a = 1 : numel(amb_prn_track)
                %h = figure(amb_prn_track(a));
                h.Name = sprintf('Sat: %d', amb_prn_track(a));
                h.NumberTitle = 'off';
                dockAllFigures();
                y = phase_res(:, a, 1);
                e = 3*phase_res(:, a, 2);
                plot(x, y,'.-', 'lineWidth', 1); hold on;
                hline = findobj(h, 'type', 'line');

                patchColor = min(hline(1).Color + 0.3, 1);
                plot(x, e, x, -e, 'color', patchColor);
                patch([x(~isnan(e)) fliplr(x(~isnan(e)))], [e(~isnan(e)); flipud(-e(~isnan(e)))], 1, ...
                    'facecolor',patchColor, ...
                    'edgecolor','none', ...
                    'facealpha', 0.1);
                lambda_val = abs(A(id_track(~isnan(y),a), 3+a));
                win_size = this.state.getMinArc() + mod(1 + this.state.getMinArc(),2);
                if numel(y(~isnan(y))) > win_size
                    half_win_size = round((win_size + 1) / 2);
                    ref = medfilt_mat(round(medfilt_mat(y(~isnan(y)), 3) ./ lambda_val) .* lambda_val, win_size);
                    ref(1 : half_win_size) = ref(half_win_size); ref(end - half_win_size + 1 : end) = ref(end - half_win_size + 1); % manage borders;
                    y(~isnan(y)) = ref;
                    plot(x, y,':k', 'LineWidth', 1); hold on;
                end
            end
        end
        
        function [phase_res, id_track] = computePhRes(this, v_hat, A, Q, obs_track, n_pos, n_tot_epoch)
            if (nargin == 1)
                v_hat = this.v_hat;
                A = this.A;
                Q = this.Q;
                obs_track = this.obs_track;
                n_pos =  this.n_pos;
                n_tot_epoch = this.n_tot_epoch;
            end
            n_amb = size(A, 2) - n_pos * 3;
                       
            % EXAMPLE: phase_res = this.computePhRes(A, Q, obs_track, amb_prn_track)
            phase_res = nan(n_tot_epoch, n_amb, 2);
            id_track = spalloc(n_tot_epoch, n_amb, round(n_tot_epoch * n_amb * 0.5));
            for a = 1 : n_amb
                % non pivot
                idx = find(A(:, 3 + a) < 0);
                res = v_hat(idx);
                phase_res(obs_track(idx, 1), a, 1) = res;
                id_track(obs_track(idx, 1), a) = idx; %#ok<*SPRIX>
                phase_res(obs_track(idx, 1), a, 2) = sqrt(Q(idx + size(Q,1) * (idx - 1)));
                
                % pivot
                %idx = find(A(:, 3 + a) > 0);
                %res = v_hat(idx);
                %phase_res(obs_track(idx, 1), a, 1) = 0;
                %id_track(obs_track(idx, 1), a) = idx; %#ok<*SPRIX>
                %phase_res(obs_track(idx, 1), a, 2) = sqrt(Q(idx + size(Q,1) * (idx - 1)));
            end
        end
    end

    % ==================================================================================================================================================
    %  GETTER FUNCTIONS goBlock
    % ==================================================================================================================================================
    
    methods % Public Access
        function toString(this)
            this.logger.addMarkedMessage('Float solution:');
            this.logger.addMessage(sprintf('       East      %12.4f   %+8.4f m\n       North     %12.4f   %+8.4f m\n       Up        %12.4f   %+8.4f m\n', ...
                [mean(this.getENU(this.getFloatPos()),1, 'omitnan')' mean(this.getDeltaENU(this.getFloatPos()),1, 'omitnan')']'));
            if this.is_fixed > 1
            this.logger.addMarkedMessage('Fixed Position:');
            this.logger.addMessage(sprintf('       East      %12.4f   %+8.4f m\n       North     %12.4f   %+8.4f m\n       Up        %12.4f   %+8.4f m\n', ...
                [mean(this.getENU(this.getFixPos()),1, 'omitnan')' mean(this.getDeltaENU(this.getFixPos()),1, 'omitnan')']'));
            end
            if this.is_fixed == 2
            this.logger.addMarkedMessage('Position @ High Rate (mean):');
            this.logger.addMessage(sprintf('       East      %12.4f   %+8.4f m\n       North     %12.4f   %+8.4f m\n       Up        %12.4f   %+8.4f m\n', ...
                [mean(this.getENU(this.getPosHR()),1, 'omitnan')' mean(this.getDeltaENU(this.getPosHR()),1, 'omitnan')']'));
            end
        end
        
        function [time_center, time_lim] = getTimeHR(this, s_rate)
            if nargin == 1
                s_rate = this.s_rate;
            end
            time_lim = unique([this.time_diff(1) : s_rate : this.time_diff(end) this.time_diff(end)]');
            time_lim = [time_lim(1 : end-1) time_lim(2 : end)];
            time_center = time_lim(:,1) + (time_lim(:,2) - time_lim(:,1)) / 2;
        end
        
        function [pos, pos_cov] = getPos(this)
            if (size(this.pos,2) > 1)
                % compute the mean of the computed positions
                
                % do not consider NaNs
                pos = this.pos;
                pos = pos(:, ~isnan(sum(pos)));
                pos_cov = this.pos_cov(~isnan(pos(:)), ~isnan(pos(:)));
                n_pos_hr = size(pos,2);
                
                % transformation matrix
                T = zeros(3, 3 * n_pos_hr);
                for i = 1 : n_pos_hr
                    T(1 : 3, (i - 1) * 3 + 1 : i * 3) = eye(3);
                end
                
                % mean position and covariance by LS
                [pos, pos_cov] = fast_least_squares_solver(pos(:), 0 * pos(:), T', pos_cov);
                pos = pos';
            else
                pos = this.pos';
                pos_cov = this.pos_cov;
            end
        end
        
        function pos = getFloatPos(this)
            pos = (repmat(this.pos0(:), 1, this.n_pos) + reshape(this.x_float(1:this.n_pos * 3), 3, this.n_pos))';
        end
        
        function [pos, pos_cov] = getFixPos(this)
            if ~(this.is_fixed)
                pos = this.getFloatPos();
                pos_cov = this.pos_cov;
            else
                pos = (repmat(this.pos0(:), 1, this.n_pos) + reshape(this.x_fix(1:this.n_pos * 3), 3, this.n_pos))';
                pos_cov = this.pos_cov_fix;
            end
        end
        
        function pos = getPosHR(this)
            if isempty(this.x_hr)
                pos = this.getFloatPos();
            else
                pos = (repmat(this.pos0(:), 1, this.n_pos_hr) + reshape(this.x_hr(1:this.n_pos_hr * 3), 3, this.n_pos_hr))';
            end
        end
        
        function ph_res = getPhaseResiduals(this)
            ph_res = nan(this.n_tot_epoch, this.state.cc.getNumSat());
            for i = 1 : size(this.phase_res,2)
                ph_res(~isnan(this.phase_res(:, i, 1)), this.amb_prn_track(i)) = this.phase_res(~isnan(this.phase_res(:, i, 1)), i, 1);
            end
        end
        
        function [empty_epoch] = getEmptyEpochs(this)
            empty_epoch = this.empty_epoch;
        end
        
        function [pos_KAL, Xhat_t_t_OUT, conf_sat_OUT, Cee_OUT, pivot_OUT, nsat, fixed_amb] = getLegacyOutput(this)
            % [pos_KAL, Xhat_t_t_OUT, conf_sat_OUT, Cee_OUT, pivot_OUT, nsat, fixed_amb] = go_block.getLegacyOutput();
            pos_KAL = this.getPos()';
            [Xhat_t_t_OUT, Cee_OUT] = this.getPos();
            Xhat_t_t_OUT = Xhat_t_t_OUT';
            conf_sat_OUT = false(this.state.cc.getNumSat(),1);
            conf_sat_OUT(unique(this.amb_prn_track)) = true;
            pivot_OUT = this.pivot_track;
            nsat = this.state.cc.getNumSat();
            fixed_amb = this.is_fixed;
        end

        function [enu] = getENU(this, pos)
            % Coordinate transformation (UTM)
            % [enu] = this.getENU(pos)
            if nargin == 1
                pos = this.pos;
            end
            if size(pos,1) ~= 3
                pos = pos';
            end
            id_ok = find(~isnan(pos(1, :)));
            up = nan(size(pos(1, :)));
            east_utm = nan(size(pos(1, :)));
            north_utm = nan(size(pos(1, :)));
            [~, ~, up(id_ok)] = cart2geod(pos(1, id_ok), pos(2, id_ok), pos(3, id_ok));
            [east_utm(id_ok), north_utm(id_ok)] = cart2plan(pos(1, id_ok)', pos(2, id_ok)', pos(3, id_ok)');

            enu = [(east_utm(:))'; (north_utm(:))'; (up(:))']';
        end

        function [delta_enu] = getDeltaENU(this, pos)
            % Coordinate transformation (UTM)
            % [delta_enu] = this.getDeltaENU(pos)
            if nargin == 1
                pos = this.pos;
            end
            if size(pos,1) ~= 3
                pos = pos';
            end
            [~, ~, up0] = cart2geod(this.pos0(1, :), this.pos0(2, :), this.pos0(3, :));
            [east_utm0, north_utm0] = cart2plan(this.pos0(1, :)', this.pos0(2, :)', this.pos0(3, :)');

            id_ok = find(~isnan(pos(1, :)));
            up = nan(size(pos(1, :)));
            east_utm = nan(size(pos(1, :)));
            north_utm = nan(size(pos(1, :)));
            [~, ~, up(id_ok)] = cart2geod(pos(1, id_ok), pos(2, id_ok), pos(3, id_ok));
            [east_utm(id_ok), north_utm(id_ok)] = cart2plan(pos(1, id_ok)', pos(2, id_ok)', pos(3, id_ok)');

            delta_enu = [(east_utm0 - east_utm(:))'; (north_utm0 - north_utm(:))'; (up0 - up(:))']';
        end
                
        function [col_ok, ref_arc, block_cols, block_rows, fs_lim] = getBlockProperties(this, A, obs_track, n_pos)
            % retrive a set of arcs (columns of A) to be removed to compute a stable solution
            % SYNTAX:  [col_ok, ref_arc,  block_cols, block_rows] = this.getBlockProperties(<A>, <obs_track>, <n_pos>)
            %
            % INTERNAL OUTPUT:
            %   this.ref_arc
            %   this.col_ok
            %
            
            if (nargin == 1)
                A = this.A;
                obs_track = this.obs_track;
                n_pos =  this.n_pos;
            end
            
            % id of the full slip epochs (goBlock restart)
            id_fs = zeros(numel(this.empty_epoch), 1);
            for i = 1 : numel(this.empty_epoch)
                tmp = find(obs_track(:,1) < this.empty_epoch(i),1,'last');
                if ~isempty(tmp)
                    id_fs(i) = tmp;
                end
            end
            id_fs(id_fs == 0) = [];
            % goBlock independent computations
            fs_lim = [[1; unique(id_fs) + 1] [unique(id_fs); size(obs_track,1)]];
            fs_lim(fs_lim(:,2)-fs_lim(:,1) < 1, :) = [];
            ref_arc = nan(size(fs_lim, 1), 1);
            
            full_slip_split = this.state.getFullSlipSplit();
            tmp = reshape(this.obs_track(fs_lim(:), 1), size(fs_lim, 1),size(fs_lim, 2));
            tmp = tmp(2:end,1)-tmp(1:end-1,2) - 1;
            id_split = (find(tmp >= full_slip_split));

            block_cols = false(size(A, 2), size(id_split, 1) + 1);
            block_rows = false(size(A, 1), size(id_split, 1) + 1);
            b = 1;
            for i = 1 : size(fs_lim, 1)
                ref_arc(i) = find(sum(A(fs_lim(i,1) : fs_lim(i,2), 3 * n_pos + 1 : end) < 0) > 0, 1, 'last');
                block_cols(:, b) = block_cols(:, b) | [ true(1, 3 * n_pos) sum(A(fs_lim(i,1) : fs_lim(i,2), 3 * n_pos + 1 : end) < 0) > 0 ]';
                block_rows(fs_lim(i, 1) : fs_lim(i, 2), b) = true;
                if ismember(i, id_split)
                    b = b + 1;
                end
            end
            col_ok = setdiff(1 : size(A, 2), ref_arc + 3 * n_pos);
            if (nargin == 1)
                this.ref_arc = ref_arc;
                this.col_ok = col_ok;
            end
        end

    end

    % ==================================================================================================================================================
    %  STATIC LAUNCHERS goBlock
    % ==================================================================================================================================================

    methods (Static) % Public Access

        function go_block = go (time_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, sp3, iono, lambda, ant_pcv, s_rate)
            % Separate the dataset in single blocks and solve float -> fix
            % go_block = Core_Block.go(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV, 3600);
            if nargin == 18
                s_rate = numel(time_diff);
            end
            go_block = Core_Block (numel(time_diff), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            go_block.prepare (time_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, sp3, iono, lambda, ant_pcv);
            go_block.solve(s_rate);
        end
        
        function go_block = goMultiHighRate(time_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, sp3, iono, lambda, ant_pcv, s_rate)
            % Separate the dataset in single blocks and solve float -> fix
            % go_block = Core_Block.goMultiHighRate(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV, 3600);
            %%
            state = Go_State.getCurrentSettings();
            logger = Logger.getInstance();
            
            idx = (unique([0 : s_rate : max(time_diff) max(time_diff)]) / state.getProcessingRate)';
            n_step = length(idx)-1;
            idx = [idx(1 : end - 1)+1 idx(2 : end)];
            idx(end, 2) = numel(time_diff());
            
            pos_hr = zeros(n_step, 3, 1);
            pos_cov_hr = zeros(3 * n_step, 3 * n_step);
            pos_fix = zeros(n_step, 3, 1);
            pos_float = zeros(n_step, 3, 1);
            
            for i = 1 : n_step
                logger.addMessage(sprintf('\nProcessing HR solution: %02d/%02d ----------------------------------\n', i, n_step));
                go_block = Core_Block (numel(time_diff(idx(i, 1) : idx(i, 2))), sum(serialize(pr1_R(:,idx(i, 1) : idx(i, 2)) ~= 0)), sum(serialize(ph1_R(:,idx(i, 1) : idx(i, 2)) ~= 0)));
                                
                go_block.prepare (time_diff(idx(i, 1) : idx(i, 2)), pos_R, pos_M, pr1_R(:,idx(i, 1) : idx(i, 2)), pr1_M(:,idx(i, 1) : idx(i, 2)), pr2_R(:,idx(i, 1) : idx(i, 2)), pr2_M(:,idx(i, 1) : idx(i, 2)), ...
                    ph1_R(:,idx(i, 1) : idx(i, 2)), ph1_M(:,idx(i, 1) : idx(i, 2)), ph2_R(:,idx(i, 1) : idx(i, 2)), ph2_M(:,idx(i, 1) : idx(i, 2)), ...
                    snr_R(:,idx(i, 1) : idx(i, 2)), snr_M(:,idx(i, 1) : idx(i, 2)),  Eph, sp3, iono, lambda, ant_pcv);
                
                go_block.solve([], false);
                
                [pos, pos_cov] = go_block.getFixPos();
                pos_hr(i,:,1) = pos;
                pos_cov_hr(1 + (i - 1) * 3 : (i * 3) , 1 + (i - 1) * 3 : (i * 3)) = pos_cov;
                pos_fix(i,:,1) = go_block.getFixPos();
                pos_float(i,:,1) = go_block.getFloatPos();
            end
            
            % Float and fix solutions are daily position in seamless mode => store the mean
            pos_float = pos_float';
            pos_fix = pos_fix';
            pos_fix = pos_fix(:, ~isnan(sum(pos_fix)));
            pos_float = pos_float(:, ~isnan(sum(pos_fix)));
            n_pos_hr = size(pos_hr, 1);
            
            % transformation matrix
            T = zeros(3, 3 * n_pos_hr);
            for i = 1 : n_pos_hr
                T(1 : 3, (i - 1) * 3 + 1 : i * 3) = eye(3) / n_pos_hr;
            end
            pos_fix = T * pos_fix(:);
            pos_float = T * pos_float(:);
                        
            go_block.import(time_diff, pos_hr', pos_cov_hr, pos_fix, pos_float);
        end

    end

    % ==================================================================================================================================================
    %  STATIC public goBlock misc utilities
    % ==================================================================================================================================================

    methods (Static) % Public Access
        
        function [x, Cxx, s02, v_hat, P_out, N_out, Cyy] = solveLS(y0, b, A, col_ok, Q, P, N)
            % Solve the LS problem, when P, N are provided it does not compute them
            % SYNTAX: [x, Cxx, s02, v_hat, P_out, N_out, Cyy] = Core_Block.solveLS(y0, b, A, col_ok, Q, P, N)
            [n_obs, n_col] = size(A);
            
            % least-squares solution
            if (nargin < 7) || isempty(P)
                P = A' / Q;
                N = P * A;
            end
            if (nargout > 4)
                P_out = P;
                N_out = N;
            end
            if numel(col_ok) < size(P,1)
                P = P(col_ok, :);
                N = N(col_ok, col_ok);
            end
            
            try
                N_inv = cholinv(full(N));
            catch
                N_inv = N^-1;
            end
            
            Y = (y0 - b);
            L = P * Y;
            x = N_inv * L;
            
            % estimation of the variance of the observation error
            y_hat = A(:, col_ok) * x + b;
            v_hat = y0 - y_hat;
            T = Q \ v_hat;
            s02 = (v_hat' * T) / (n_obs - n_col);
                        
            % covariance matrix
            Cxx = s02 * N_inv;
            
            if nargout == 7
                A = A(:, col_ok)';
                Cyy = s02 * A' * N_inv * A;
            end
        end
    end

    % ==================================================================================================================================================
    %  PRIVATE FUNCTIONS called by pubblic calls goBlock
    % ==================================================================================================================================================

    methods (Access = private)
        
        function [A, col_ok, ref_arc, y0, b, Q, obs_track, amb_prn_track] = remUnstableArcs(A, col_ok, ref_arc, y0, b, Q, obs_track, amb_prn_track, Cxx)
            % If the system is unstable remove the arcs that are making it so
            amb_var = zeros(size(Cxx,1) + numel(ref_arc)); amb_var(col_ok) = diag(Cxx); amb_var(amb_var < 0) = 100;
            % Bad arcs have an high estimation variance
            bad_col = find((amb_var(4:end) > 10) | (amb_var(4:end) > mean(amb_var(col_ok(4 : end))) + 10 * std(amb_var(col_ok(4 : end))))) + 3;
            Q_tmp = Q;
            while ~isempty(bad_col) && (size(A,2) >= 3 + 2)
                bad_col = bad_col(1);
                this.logger.addMessage(sprintf('       - System found unstable, removing arc %d - prn %d', bad_col - 3, amb_prn_track(bad_col - 3)));
                [A, y0, b, Q, obs_track, amb_prn_track] = this.remArcCol(A, y0, b, Q, obs_track, amb_prn_track, bad_col);
                [A, y0, b, Q, obs_track, amb_prn_track] = this.remShortArc(A, y0, b, Q, obs_track, amb_prn_track, this.state.getMinArc());
                [col_ok, ref_arc] = this.getBestRefArc(y0, b, A, Q);
                [~, Cxx, ~, ~, Q_tmp] = this.improveFloatSolution(y0, b, A, col_ok, Q, [], obs_track);
                amb_var = zeros(size(Cxx,1) + numel(ref_arc)); amb_var(col_ok) = diag(abs(Cxx));
                bad_col = find((amb_var(4:end) > 10) | (amb_var(4:end) > mean(amb_var(col_ok(4 : end))) + 10 * std(amb_var(col_ok(4 : end))))) + 3;
            end
            Q = Q_tmp;
        end
        
        function [x_float, Cxx, y0, Q_tmp, s02, v_hat] = loopCorrector(this, y0, b, A, col_ok, Q, obs_track, amb_prn_track, phase_res, id_track, n_clean)
            % Try to correct integer ambiguities (maybe missed cycle slips) on the basis of the residuals
            % SYNTAX: [x_float, y0, Cxx] = this.loopCorrector(y0, b, A, col_ok, Q, obs_track, amb_prn_track, phase_res, id_track, n_clean);
                Q_tmp = Q;
                c = 1; is_new = true;
                x_float = [];
                Cxx = [];
                while (c <= n_clean) && is_new
                    % Try to correct integer ambiguities (maybe missed cycle slips)
                    this.logger.addMessage(sprintf('       - try to fix previously undetected cycle slips %d/%d', c , n_clean));
                    win_size = (this.state.getMinArc()/2 + mod(1 + this.state.getMinArc()/2, 2));
                    [y0, is_new] = this.postCorrectIntAmb(y0, phase_res, id_track, A, amb_prn_track, win_size);
                    
                    if is_new
                        % Improve solution by iterative increase of bad observations variance
                        %this.logger.addMessage('          - recompute the improved solution');
                        [~, ~, ~, v_hat] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
                        [x_float, Cxx, s02, v_hat, Q_tmp] = this.improveFloatSolution(y0, b, A, col_ok, Q, v_hat, obs_track);
                        if c < n_clean
                            [phase_res, id_track] = this.computePhRes( v_hat, A, Q, obs_track, 1, size(A,1));
                        end
                    else
                        this.logger.addMessage('          - no cycle slips have been found!');
                    end
                    
                    c = c + 1;
                end
                if isempty(Cxx)
                    [x_float, Cxx, s02, v_hat] = this.solveLS(y0, b, A, col_ok, Q_tmp);
                end
        end
        
        function [id_out, phase_res] = phaseCleaner(this, phase_res, id_track, thr_fix)
            % clean phase residuals and suggest outliers
            % SYNTAX: [id_out, phase_res] = phaseCleaner(this, phase_res, id_track, thr_fix);
            narginchk(3,4);
            if nargin == 3
                thr_fix = this.state.getMaxPhaseErrThr();
            end

            win_size = this.state.getMinArc() + mod(1 + this.state.getMinArc(),2);
            half_win_size = round(this.state.getMinArc() / 2) + mod(1 + round(this.state.getMinArc() / 2),2);
            id_out = [];
            for i = 1 : size(phase_res, 2)
                phase = phase_res(:,i, 1);
                phase_s = splinerMat([],movmedian(phase, win_size, 'omitnan'),half_win_size, 0.01);
                thr = 15 * median(movstd(phase-phase_s, 11, 'omitnan'), 'omitnan');
                id = find(abs(phase - phase_s) > thr | abs(phase) > thr_fix);
                phase_res(id, i, 1) = NaN;
                id_out = [id_out; id_track(id, i)]; %#ok<AGROW>
            end
        end

        function import(this, time_diff, pos_hr, pos_cov, pos_fix, pos_float)
            this.time_diff = time_diff;
            this.is_fixed = 2;
            this.s_rate = this.state.getSolutionRate();
            this.n_pos_hr = numel(pos_hr)/3;
            this.pos = pos_hr;
            this.pos_cov = pos_cov;
            this.x_hr = pos_hr(:) - repmat(this.pos0(:), this.n_pos_hr, 1);
            this.x_fix = pos_fix - repmat(this.pos0(:), this.n_pos, 1);
            this.x_float = pos_float - repmat(this.pos0(:), this.n_pos, 1);
            this.n_pos = numel(pos_float)/3;
            this.amb_fix = [];
            this.amb_fix_full = [];
        end
        
        function addAmbiguities (this, lambda)
            % Add to the internal Design Matrix the columns related to the phase observations
            % (Integer ambiguities - N)
            %
            % METHODS CALL REQUIREMENTS:
            %  -> prepare
            %
            % SYNTAX:
            %   this.addAmbiguities(lambda)
            %
            % INPUT:
            %   lambda     wavelength matrix (depending on the enabled constellations)
            %
            % INTERNAL INPUT:
            %   A, amb_prn_track, n_pos, n_obs_tot, sat_ph_track
            %
            % INTERNAL OUTOUT (properties whos values are changed):
            %   A, amb_prn_track
            %
            % EXAMPLE:
            %   go_block = Core_Block(numel(time_GPS), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            %   go_block.prepare(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV);

            this.logger.addMarkedMessage('Set up Design Matrix to estimate integer abiguities');

            if (this.state.isModePh())
                sat_avail = any(this.sat_ph_track, 2);
                amb_num = sum(sat_avail);
                amb_prn = find(sat_avail);
                this.amb_prn_track = amb_prn;
                amb_idx = 1 : amb_num;
            end
            full_slip_split = this.state.getFullSlipSplit();
            [full_slip, ia] = unique(this.empty_epoch(:) - (0 : length(this.empty_epoch) - 1)');
            full_slip = full_slip(find(diff(ia) > full_slip_split-1));
            if (this.state.isModeSA())
                % set the design matrix to estimate the receiver clock
                this.A(:, 3 + 1) = 1;

                % clear A avoid problems when launching addAmbiguities() more than once
                this.A = this.A(:, 1 : 3 + 1);
            else
                % clear A avoid problems when launching addAmbiguities() more than once
                this.A = this.A(:, 1 : 3);
                if (this.state.isModePh())
                    % matrix to detect re-initialized ambiguities
                    % every time there is an interruption in the satellite observations -> suppose cs
                    amb_track = [int8(zeros(size(this.sat_ph_track,1), 1)) diff(this.sat_ph_track')'];
                    % Cycle slip at pivot change
                    % pivot_change = (abs(diff([int8(this.pivot_track(1)) int8(this.pivot_track')])) > 0);
                    % amb_track = amb_track ...
                    %     + int8(this.sat_ph_track & repmat(pivot_change,size(this.sat_ph_track,1),1)) ...
                    %     - int8(this.sat_ph_track & repmat([pivot_change(2:end) pivot_change(1)],size(this.sat_ph_track,1),1));
                    for i = 1 : length(full_slip)
                        amb_track(this.sat_ph_track(:,full_slip(i)) > 0, full_slip(i)) = 1;
                        amb_track((this.sat_ph_track(:,full_slip(i) - 1) > 0) & (sum(this.sat_ph_track(:,1 : full_slip(i) - 1), 2) > 0), full_slip(i) - 1) = -1;
                    end
                    
                    % resize the design matrix to estimate phase ambiguities
                    this.A = [this.A sparse(this.n_obs_tot, amb_num)];
                    rows = 0;
                    for e = 1 : this.n_epoch

                        % check if a new ambiguity column for A is needed

                        % detect new ambiguities on epoch e
                        amb_prn_new = find(amb_track(:,e) == 1);
                        if (~isempty(amb_prn_new))
                            [~, amb_idx_new] = intersect(amb_prn, amb_prn_new);

                            % add a new amb column for the same satellite only if it already had estimates previously
                            old_amb = find(any(amb_track(:,1:e-1) == -1, 2));
                            [amb_prn_new, idx] = intersect(amb_prn_new, old_amb);
                            amb_idx_new = amb_idx_new(idx);

                            if (~isempty(amb_prn_new))
                                amb_idx(amb_idx_new) = max(amb_idx) + (1 : length(amb_prn_new));
                                amb_num = amb_num + length(amb_prn_new);
                                this.amb_prn_track = [this.amb_prn_track; amb_prn_new];
                                this.A = [this.A sparse(this.n_obs_tot, numel(amb_idx_new))];
                            end
                        end

                        % build new columns
                        pivot_prn = this.pivot_track(e);
                        this.sat_pr_track(pivot_prn, e) = -1;
                        this.sat_ph_track(pivot_prn, e) = -1;

                        amb_prn_avail = find(this.sat_ph_track(:,e) == 1);
                        [~, amb_idx_avail] = intersect(amb_prn, amb_prn_avail);
                        pivot_id = amb_idx(amb_prn == pivot_prn);
                        %sat_ph_idx = sum(this.sat_pr_track(:,e) == 1) + (1 : sum(this.sat_ph_track(:, e) == 1));
                        sat_ph_idx = sum(this.sat_pr_track(:,e) == 1) + (1 : sum(this.sat_ph_track(:, e) == 1));
                        rows = rows(end) + sat_ph_idx;
                        this.A(rows + size(this.A,1) * (3 + amb_idx(amb_idx_avail) -1)) = - lambda(amb_prn_avail, 1);
                        this.A(rows + size(this.A,1) * (3 + pivot_id -1)) = lambda(amb_prn_avail,1);
                    end
                    %[this.amb_prn_track, reorder_id] = sort(this.amb_prn_track);
                    %this.A = this.A(:, [(1 : (3))'; (3) + reorder_id]);
                end
            end
        end
                
        function [d_pos, pos_cov, is_fixed, amb_fix, amb_cov, amb_fix_full, ref_arc, G] = solveFixPar (this, x_float, Cxx, amb_num)
            % Compute a fixed solution using LAMBDA, and the the internal object properties (Concrete implementation)
            %
            % METHODS CALL REQUIREMENTS:
            %   prepare -> addAmbiguities -> solveFloat
            %
            % SYNTAX:
            %   [d_pos, pos_cov, amb_fix, amb_cov, amb_fix_full, ref_arc] = this.solveFix()
            %
            % INPUT:
            %   x_float     Float solution
            %   Cxx         Covariance matrix of the solution
            %   amb_num     Ambiguities number
            %
            % INTERNAL INPUT:
            %   logger
            %
            % OUTPUT:
            %   d_pos       coordinates offset of the estimated positions
            %   pos_cov         covariance of the estimated positions
            %   is_fixed        flag is fixed?
            %   amb_fix       ambiguities as estimated by lambda (n-1 w.r.t. float solution)
            %   amb_cov         ambiguities error covariance matrix
            %   amb_fix_full ambbiguities as converted from fix to float -> to be imported as pseudo observations of the float solution
            %   ref_arc         arc used as reference in the fix solution (it's the arc that create a bias in the solution)
            %            %
            % EXAMPLE:
            %   go_block = Core_Block(numel(time_GPS), sum(serialize(pr1_R(:,:,1) ~= 0)), sum(serialize(ph1_R(:,:,1) ~= 0)));
            %   go_block.prepare(time_GPS_diff, pos_R, pos_M, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M,  Eph, SP3, iono, lambda, antenna_PCV);
            %   go_block.addAmbiguities(lambda)
            %   go_block.solveFloat()
            %   go_block.solveFix()
            %

            % Compute a first float solution
            if (nargin < 3) || (isempty(x_float))
                this.solveFloat();
                x_float = this.x_float;
                Cxx = this.Cxx;
                amb_num = size(this.A, 2) - 3 - numel(this.ref_arc);
            end

            % switch from SD to DD
            D = zeros(amb_num - 1, amb_num);
            % find best estimated arc:
            %[~, ref_arc] = sort(diag(Cxx(4 : end, 4 : end))); ref_arc = ref_arc(1);
            ref_arc = 1; % there are no differences choosing one arc or another (~1e-10 differences in the results)
            D(:, ref_arc) = 1;
            D(:, [1 : ref_arc - 1, ref_arc + 1 : end]) = -eye(amb_num - 1);
            G = zeros(3 + amb_num - 1, 3 + amb_num);
            G(1 : 3, 1 : 3) = eye(3);
            G(4 : end, 4 : end) = D;
            x = G * x_float;
            Cxx = full(G * Cxx * G');

            cov_X  = Cxx(1 : 3, 1 : 3);     % position covariance block
            cov_N  = Cxx(4 : end, 4 : end); % ambiguity covariance block
            cov_XN = Cxx(1 : 3, 4 : end);   % position-ambiguity covariance block

            is_fixed = 0;
            try
                try
                    % stabilize cov_N;
                    [U] = chol(cov_N);
                    cov_N = U'*U;
                catch ex
                    this.logger.addWarning(sprintf('Phase ambiguities covariance matrix unstable - %s', ex.message));
                end

                % integer phase ambiguity solving by LAMBDA
                [d_pos_ck, amb_fix_ck, amb_cov, pos_cov, d_pos, amb_fix] = lambdafix(x(1:3), x(4:end), cov_X, cov_N, cov_XN);

                if sum(amb_fix_ck == x(4:end))
                    this.logger.addWarning('LAMBDA returned a fixed solution that did not pass the ratio test\nTring to use the solution anyway');
                end
                
                n_cands = size(amb_fix, 2);
                
                amb_fix_full = zeros(amb_num, n_cands);
                amb_fix_full([1 : ref_arc - 1, ref_arc + 1 : end],:) = -(amb_fix - repmat(x_float(ref_arc + 3), 1, n_cands));
                amb_fix_full(ref_arc,:) = repmat(x_float(3 + ref_arc), 1, n_cands);
                
                x_new = [repmat(x(1 : 3), 1, n_cands); [amb_fix_full]];
                y_hat = this.A(:, this.col_ok)  * x_new + repmat(this.b, 1, n_cands);
                v_hat = repmat(this.y0, 1, n_cands) - y_hat;
                T = this.Q \ v_hat;
                s02 = diag((v_hat' * T) / (size(this.A, 1) - numel(this.col_ok)));
                [~, id_best] = sort(s02); id_best = id_best(1);
                
                amb_fix = amb_fix(:, id_best);
                d_pos = d_pos(:, id_best);
                amb_fix_full = amb_fix_full(:, id_best);
                is_fixed = 1;
            catch ex
                this.logger.addWarning(sprintf('It was not possible to estimate integer ambiguities: a float solution will be output.\n%s',ex.message));
                pos_cov = cov_X;
                amb_cov = cov_N;
                amb_fix_full = x_float(4 : end);
                amb_fix = amb_fix_full;
                d_pos = x_float(1 : 3);
                ref_arc = 0;
            end
        end

        function [x_float, Cxx, s02, v_hat, Q] = improveFloatSolution(this, ...
                    y0, b, A, col_ok, Q, ...
                    v_hat, obs_track, thr)
            % Stabilize solution by increasing bad observations variances
            %
            % SYNTAX:
            %   [x_float, Cxx, s02, v_hat, Q] = this.improveFloatSolution(this, y0, b, A, col_ok, Q, v_hat, obs_track)

            x_float = [];
            if isempty(v_hat)
                [x_float, Cxx, s02, v_hat] = this.solveLS(y0, b, A, col_ok, Q);
            end
            
            narginchk(7,8);
            if nargin == 8
                thr = 0;
            end
            
            search_for_outlier = 1;

            out_ph_old = false(size(obs_track,1),1);
            out_pr_old = false(size(obs_track,1),1);
            n_out_old = 0;
            idx_pr = find(obs_track(:,3) == -1);
            idx_ph = find(obs_track(:,3) == 1);
            while (search_for_outlier == 1)
                % never remove more than 0.5% of data at time
                out_pr = abs(v_hat(idx_pr)) > max(thr, max(this.state.getMaxCodeErrThr() , perc(abs(v_hat(~out_pr_old)), 0.995)));
                if isempty(out_pr)
                    out_pr = out_pr_old;
                end
                out_ph = abs(v_hat(idx_ph)) > max(thr, max(this.state.getMaxPhaseErrThr() , perc(abs(v_hat(~out_ph_old)), 0.995)));
                if isempty(out_ph)
                    out_ph = out_ph_old;
                end
                n_out = sum(out_pr_old | out_pr | out_ph_old | out_ph);
                idx_out_pr = idx_pr(out_pr);
                idx_out_ph = idx_ph(out_ph);
                if n_out_old < n_out
                    n_out_old = n_out;
                    out_pr_old = out_pr_old | out_pr;
                    out_ph_old = out_ph_old | out_ph;
                    idx_out = [idx_out_pr idx_out_ph];
                    Q(idx_out + size(Q,1) * (idx_out - 1)) = max(Q(idx_out + size(Q,1) * (idx_out - 1)) * 1.2, 1.2 * (v_hat(idx_out)).^2); % Bad observations have now their empirical error

                    [x_float, Cxx, s02, v_hat] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
                else
                    if isempty(x_float)
                        [x_float, Cxx, s02, v_hat] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
                    end
                    search_for_outlier = 0;
                end
            end
        end

        function [x_float, Cxx, s02, v_hat, y0, b, A, col_ok, Q, obs_track, amb_prn_track]  = cleanFloatSolution (this, ...
                    y0, b, A, col_ok, Q, ...
                    v_hat, obs_track, amb_prn_track, thr)
            % Stabilize solution by removing observations eith high residuals
            % [x_float, Cxx, s02, v_hat, y0, b, A, Q, obs_track, amb_prn_track] = cleanFloatSolution(this, y0, b, A, Q, v_hat, obs_track, amb_prn_track)

            x_float = [];
            search_for_outlier = 1;

            if nargin < 9
                thr = 3;
            end

            out_ph_old = false(size(v_hat));
            out_pr_old = false(size(v_hat));
            while (search_for_outlier == 1)
                idx_pr = find(obs_track(:,3) == -1);
                idx_ph = find(obs_track(:,3) == 1);
                % never remove more than 0.5% of data at time
                out_pr = abs(v_hat(idx_pr)) > max(max(this.state.getMaxCodeErrThr() , thr * sqrt(Q(idx_pr + size(Q,1) * (idx_pr - 1)))), perc(abs(v_hat), 0.995));
                if isempty(out_pr)
                    out_pr = out_pr_old;
                end
                out_ph = abs(v_hat(idx_ph)) > max(max(this.state.getMaxPhaseErrThr() , thr * sqrt(Q(idx_ph + size(Q,1) * (idx_ph - 1)))), perc(abs(v_hat), 0.995));
                if isempty(out_ph)
                    out_ph = out_ph_old;
                end
                idx_out_pr = idx_pr(out_pr);
                idx_out_ph = idx_ph(out_ph);
                idx_out = [idx_out_pr idx_out_ph];
                if (~isempty(idx_out))
                    y0(idx_out) = [];
                    A(idx_out,:) = [];
                    Q(idx_out,:) = [];
                    Q(:,idx_out) = [];
                    b(idx_out) = [];
                    obs_track(idx_out,:) = [];
                    
                    n_col = size(A,2);
                    [A, y0, b, Q, obs_track, amb_prn_track] = this.remShortArc(A, y0, b, Q, obs_track, amb_prn_track, this.state.getMinArc());
                    % If I removed an arc re-estimate the best arc
                    if size(A,2) < n_col
                        [col_ok] = this.getBestRefArc(y0, b, A, Q);
                    end
                    [x_float, Cxx, s02, v_hat] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
                else
                    if isempty(x_float)
                        [x_float, Cxx, s02, v_hat] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
                    end
                    search_for_outlier = 0;
                end
            end
        end

        function [x_float, Cxx, s02, v_hat, y0, b, A, col_ok, Q, obs_track, amb_prn_track]  = remSolitaryObs (this, ...
                y0, b, A, col_ok, Q, ...
                obs_track, amb_prn_track, min_contiguous_obs)

            amb_num = numel(amb_prn_track);

            idx_pr = (obs_track(:,3) == -1); %#ok<NASGU>
            idx_ph = (obs_track(:,3) == 1);

            idx_out = [];
            for a = 1 : amb_num
                % find obs of an arc
                id_obs_ok = find(full(idx_ph & (A(:,3 + a) < 0)));
                % find the epochs of these obs
                id_epoch_ok = zeros(max(obs_track(:,1)),1);
                id_epoch_ok(obs_track(id_obs_ok)) = id_obs_ok;
                [lim] = getOutliers(id_epoch_ok);
                lim_ko = find(lim(:,2)-lim(:,1) + 1 < min_contiguous_obs);

                for i = 1 : numel(lim_ko)
                    idx_out = [idx_out; id_epoch_ok(lim(lim_ko(i), 1) : lim(lim_ko(i), 2))]; %#ok<AGROW>
                end
            end
            idx_out = sort(idx_out);

            y0(idx_out) = [];
            A(idx_out,:) = [];
            Q(idx_out,:) = [];
            Q(:,idx_out) = [];
            b(idx_out) = [];
            obs_track(idx_out,:) = [];
            
            n_col = size(A, 2);
            [A, y0, b, Q, obs_track, amb_prn_track] = this.remShortArc(A, y0, b, Q, obs_track, amb_prn_track, this.state.getMinArc());
            if size(A, 2) < n_col
                [col_ok] = this.getBlockProperties(A, obs_track, 1);
            end
            [x_float, Cxx, s02, v_hat] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
        end
        
%         function [y0, Q] = preCorrectObsIntAmb(this)
%             A = this.A;
%             Q = this.Q;
%             n_pos =  this.n_pos;
%             y0 = this.y0 - this.b;
%
%             % epoch of a change of pivot
%             pivot_change = find(abs(diff(int8(this.pivot_track)))>0);
%
%             n_amb = size(A, 2) - n_pos * 3;
%
%             % First loop find discontinuities in the observations
%             for a = 1 : n_amb
%                 idx = find(A(:, 3 + a) < 0);
%
%                 if numel(idx > 3)
%
%                     lambda_obs = abs(this.A(idx(1), a + this.n_pos * 3));
%
%                     tmp = [0; diff(y0(idx)) / lambda_obs];
%                     tmp = round(cumsum(tmp - movmedian(tmp, 3)));
%
%                     % discontinuities due to a change of pivot are wanted
%                     for i = 1 : numel(pivot_change)
%                         [~, jmp] = intersect(idx, find(this.obs_track(:,1) == pivot_change(i)));
%                         jmp = jmp + sum(this.empty_epoch < pivot_change(i));
%                         if (jmp < length(tmp)-1)
%                             tmp(jmp+1:end) = tmp(jmp+1:end) - (tmp(jmp+1) - tmp(jmp));
%                         end
%                     end
%                     tmp = movmedian(tmp,3);
%
%                     % remove the integer discontinuities in the observations
%                     y0(idx) = y0(idx) - tmp * lambda_obs;
%                 end
%             end
%
%             [~, ~, ~, v_hat] = fast_least_squares_solver(y0 + this.b, this.b, this.A(:, this.col_ok), this.Q);
%             [~, ~, ~, v_hat] = this.improveFloatSolution(y0 + this.b, this.b, this.A, this.col_ok, this.Q, v_hat, this.obs_track);
%
%             for a = 1 : n_amb
%                 idx = find(A(:, 3 + a) < 0);
%                 if numel(idx > 3)
%
%                     % lambda_obs = abs(this.A(idx(1), a + this.n_pos * 3));
%                     % tmp = round(v_hat(idx) / lambda_obs) * lambda_obs;
%                     % y0(idx) = y0(idx) - tmp;
%
%                     % clean obs jmp
%                     res = [0; diff(y0(idx)) - movmedian(diff(y0(idx)), 3)];
%                     id_ko = abs(res) > 0.04;
%                     id_ko = idx(id_ko(1:end-1) & id_ko(2:end));
%                     Q(id_ko + size(Q,1) * (id_ko - 1)) = Q(id_ko + size(Q,1) * (id_ko - 1)) * 4;
%                     %Q(id_ko + size(Q,1) * (id_ko - 1)) = v_hat(id_ko).^2;
%                 end
%             end
%
%             y0 = y0 + this.b;
%         end
        
        function [y0, Q] = preCorrectObsIntAmb(this, y0, b, A, col_ok, Q, n_pos, obs_track, pivot_change)
            if nargin == 1
                y0 = this.y0 - this.b;
                b = this.b;
                A = this.A;
                Q = this.Q;
                n_pos =  this.n_pos;
                obs_track = this.obs_track;
            
                col_ok = this.col_ok;
                empty_epoch = this.empty_epoch;
            else
                empty_epoch = [];
                y0 = y0 - b;
            end
                        
            n_amb = size(A, 2) - n_pos * 3;
                        
            % First loop find discontinuities in the observations
            for a = 1 : n_amb
                idx = find(A(:, 3 + a) < 0);
               
                if numel(idx > 3)
                    
                    lambda_obs = abs(A(idx(1), a + n_pos * 3));
                    
                    tmp = [0; diff(y0(idx))];
                    tmp = round(cumsum(tmp - movmedian(tmp, 3)) / lambda_obs) * lambda_obs;
                    tmp = movmedian(tmp,3);
%                     tmp1 = [0; diff(y0(idx) - tmp)];
%                     tmp1(abs(tmp1) < 0.4 * lambda_obs) = 0;
%                     tmp1 = round(cumsum(tmp1) / lambda_obs) * lambda_obs;
%                     tmp = tmp + tmp1;
                    
                    % discontinuities due to a change of pivot are wanted
                    for i = 1 : numel(pivot_change)
                        [~, jmp] = intersect(idx, find(obs_track(:,1) == pivot_change(i)));
                        jmp = jmp + sum(empty_epoch < pivot_change(i));
                        if (jmp < length(tmp)-1)
                            tmp(jmp+1:end) = tmp(jmp+1:end) - (tmp(jmp+1) - tmp(jmp));
                        end
                    end
                    
                    % remove the integer discontinuities in the observations
                    y0(idx) = y0(idx) - tmp * lambda_obs;
                end
            end
            
            [~, ~, ~, v_hat] = fast_least_squares_solver(y0 + b, b, A(:, col_ok), Q);
            [~, ~, ~, ~] = this.improveFloatSolution(y0 + b, b, A, col_ok, Q, v_hat, obs_track);
            
            for a = 1 : n_amb
                idx = find(A(:, 3 + a) < 0);
                if numel(idx > 3)

                    % lambda_obs = abs(this.A(idx(1), a + this.n_pos * 3));
                    % tmp = round(v_hat(idx) / lambda_obs) * lambda_obs;
                    % y0(idx) = y0(idx) - tmp;
                    
                    % clean obs jmp
                    res = [0; diff(y0(idx)) - movmedian(diff(y0(idx)), 3)];
                    id_ko = abs(res) > 0.04;
                    id_ko = idx(id_ko(1:end-1) & id_ko(2:end));
                    Q(id_ko + size(Q,1) * (id_ko - 1)) = Q(id_ko + size(Q,1) * (id_ko - 1)) * 4;
                    %Q(id_ko + size(Q,1) * (id_ko - 1)) = v_hat(id_ko).^2;
                end
            end
            
            y0 = y0 + b;
        end
        
        function [y0, is_new] = postCorrectIntAmb (this, ...
                    y0, phase_res, id_track, ...
                    A, amb_prn_track, win_size)
            % try to correct integer ambiguities by using a moving median on the LS residuals
            % fixed at n * lambda levels.
            % Note that the solution MUST be stable to perform this action
            %
            % SYNTAX:
            %   [y0] = postCorrectIntAmb(this, y0, phase_res, id_track, A, amb_prn_track)
            %
            % OUTPUT:
            %   y0      array with "corrected" integer ambiguities
            %   is_new  flag -> true when y0 has been changed
            if (nargin < 7)
                win_size = this.state.getMinArc() + mod(1 + this.state.getMinArc(),2);
            end
            
            is_new = false;
            half_win_size = round((win_size + 1) / 2);
            for a = 1 : numel(amb_prn_track)
                y = phase_res(:, a, 1);
                id_obs = id_track(~isnan(y),a);
                lambda_val = abs(A(id_obs, 3 + a));
                if (numel(y(~isnan(y))) > 1.5 * win_size) % it's probably a pivot
                    ref = movmedian(round(medfilt_mat(y(~isnan(y)), 3) ./ lambda_val) .* lambda_val, win_size, 'omitnan');
                    ref(abs(movmedian(diff([ref(1); ref]),3)) > 0) = 0;
                    ref(1 : half_win_size) = ref(half_win_size); ref(end - half_win_size + 1 : end) = ref(end - half_win_size + 1); % manage borders;
                    % If the ref correction provides a reduction of the derivative std -> use it
                    if (std(diff(y(~isnan(y))-ref)) <= std(diff(y(~isnan(y)))))
                        is_new = true;
                        y0(id_obs) = y0(id_obs) - ref;
                    end
                end
            end
        end

        function [y0, A, b, Q, sat_pr_track, sat_ph_track, pivot] =  oneEpochLS (this, ...
                    time_rx, ...
                    pos_r, pos_m, ...
                    pr1_r, pr1_m, pr2_r, pr2_m, ...
                    ph1_r, ph1_m, ph2_r, ph2_m, ...
                    snr_r, snr_m, ...
                    eph, sp3, iono, lambda, frequencies, ant_pcv)

            % SYNTAX:
            %   prepare_dd_sys(time_rx, XR0, XM, pr1_R, pr1_M, pr2_R, pr2_M, ph1_R, ph1_M, ph2_R, ph2_M, snr_R, snr_M, Eph, sp3, iono, lambda, phase, ant_pcv);
            %
            % INPUT:
            %   time_rx = GPS reception time
            %   XR0   = ROVER approximate position
            %   XM    = MASTER position
            %   pr1_R = ROVER code observations (L1 carrier)
            %   pr1_M = MASTER code observations (L1 carrier)
            %   pr2_R = ROVER code observations (L2 carrier)
            %   pr2_M = MASTER code observations (L2 carrier)
            %   ph1_R = ROVER phase observations (L1 carrier)
            %   ph1_M = MASTER phase observations (L1 carrier)
            %   ph2_R = ROVER phase observations (L2 carrier)
            %   ph2_M = MASTER phase observations (L2 carrier)
            %   snr_R = ROVER-SATELLITE signal-to-noise ratio
            %   snr_M = MASTER-SATELLITE signal-to-noise ratio
            %   Eph   = satellite ephemeris
            %   sp3   = structure containing precise ephemeris and clock
            %   iono  = ionosphere parameters
            %   lambda = wavelength matrix (depending on the enabled constellations)
            %   phase  = L1 carrier (phase=1), L2 carrier (phase=2)
            %   ant_pcv = antenna phase center variation
            %
            % DESCRIPTION:
            %   Computation of the receiver position (X,Y,Z).
            %   Relative (double difference) positioning by least squares adjustment
            %   on code and phase observations.

            cutoff = this.state.cut_off;
            snr_threshold = this.state.snr_thr;
            cond_n_threshold = this.state.cond_num_thr;

            y0 = [];
            A  = [];
            b  = [];
            Q  = [];

            %total number of satellite slots (depending on the constellations enabled)
            n_sat_tot = size(pr1_r,1);

            %topocentric coordinate initialization
            azR   = zeros(n_sat_tot,1);
            elR   = zeros(n_sat_tot,1);
            distR = zeros(n_sat_tot,1);
            azM   = zeros(n_sat_tot,1);
            elM   = zeros(n_sat_tot,1);
            distM = zeros(n_sat_tot,1);

            %--------------------------------------------------------------------------------------------
            % SATELLITE SELECTION
            %--------------------------------------------------------------------------------------------

            % Find sat in common, between master and rover
            if (length(frequencies) == 2)
                sat_pr = pr1_r & pr1_m & pr2_r & pr2_m;
                sat_ph = ph1_r & ph1_m & ph2_r & ph2_m;
            else
                if (frequencies == 1)
                    sat_pr = pr1_r & pr1_m;
                    sat_ph = ph1_r & ph1_m;
                else
                    sat_pr = pr2_r & pr2_m;
                    sat_ph = ph2_r & ph2_m;
                end
            end

            % filter satellites with no ephemeris
            if (isempty(sp3))
                eph_avail = eph(30,:);
            else
                eph_avail = sp3.avail;
            end
            sat_pr = find(sat_pr & eph_avail);
            sat_ph = find(sat_ph & eph_avail);

            min_nsat_LS = 3 + this.state.cc.getNumSys();

            flag_XR = 2;

            % satellite configuration
            sat_pr_track = int8(zeros(n_sat_tot, 1));
            sat_ph_track = int8(zeros(n_sat_tot, 1));
            pivot = 0;

            if (size(sat_pr,1) >= min_nsat_LS)

                sat_pr_old = sat_pr;

                if (frequencies == 1)
                    [pos_m, dtM, XS, dtS, XS_tx, VS_tx, time_tx, err_tropo_M, err_iono_M, sat_pr_M, elM(sat_pr_M), azM(sat_pr_M), distM(sat_pr_M), sys, cov_XM, var_dtM] ...
                        = init_positioning(time_rx, pr1_m(sat_pr),   snr_m(sat_pr),   eph, sp3, iono, [],  pos_m, [],  [], sat_pr,    [], lambda(sat_pr,:),   cutoff, snr_threshold, frequencies,       2, 0, 0, 0); %#ok<ASGLU>
                    if (sum(sat_pr_M) < min_nsat_LS); return; end
                    [XR, dtR, XS, dtS,     ~,     ~,       ~, err_tropo_R, err_iono_R, sat_pr_R, elR(sat_pr_R), azR(sat_pr_R), distR(sat_pr_R), sys, cov_XR, var_dtR, PDOP, HDOP, VDOP, cond_num] ...
                        = init_positioning(time_rx, pr1_r(sat_pr_M), snr_r(sat_pr_M), eph, sp3, iono, [], pos_r, XS, dtS, sat_pr_M, sys, lambda(sat_pr_M,:), cutoff, snr_threshold, frequencies, flag_XR, 1, 0, 0); %#ok<ASGLU>
                else
                    [pos_m, dtM, XS, dtS, XS_tx, VS_tx, time_tx, err_tropo_M, err_iono_M, sat_pr_M, elM(sat_pr_M), azM(sat_pr_M), distM(sat_pr_M), sys, cov_XM, var_dtM] ...
                        = init_positioning(time_rx, pr2_m(sat_pr),   snr_m(sat_pr),   eph, sp3, iono, [],  pos_m, [],  [], sat_pr,    [], lambda(sat_pr,:),   cutoff, snr_threshold, frequencies,       2, 0, 0, 0); %#ok<ASGLU>
                    if (sum(sat_pr_M) < min_nsat_LS); return; end
                    [XR, dtR, XS, dtS,     ~,     ~,       ~, err_tropo_R, err_iono_R, sat_pr_R, elR(sat_pr_R), azR(sat_pr_R), distR(sat_pr_R), sys, cov_XR, var_dtR, PDOP, HDOP, VDOP, cond_num] ...
                        = init_positioning(time_rx, pr2_r(sat_pr_M), snr_r(sat_pr_M), eph, sp3, iono, [], pos_r, XS, dtS, sat_pr_M, sys, lambda(sat_pr_M,:), cutoff, snr_threshold, frequencies, flag_XR, 1, 0, 0); %#ok<ASGLU>
                end

                %keep only satellites that rover and master have in common
                [sat_pr, iR, iM] = intersect(sat_pr_R, sat_pr_M);
                XS = XS(iR,:);
                sys = sys(iR);
                if (~isempty(err_tropo_R))
                    err_tropo_R = err_tropo_R(iR);
                    err_iono_R  = err_iono_R (iR);
                    err_tropo_M = err_tropo_M(iM);
                    err_iono_M  = err_iono_M (iM);
                end

                %apply cutoffs also to phase satellites
                sat_removed = setdiff(sat_pr_old, sat_pr);
                sat_ph(ismember(sat_ph,sat_removed)) = [];

                % keep only satellites that rover and master have in common both in phase and code
                [sat_pr, iR, iM] = intersect(sat_pr, sat_ph);
                XS = XS(iR,:);
                sys = sys(iR);
                if (~isempty(err_tropo_R))
                    err_tropo_R = err_tropo_R(iR);
                    err_iono_R  = err_iono_R (iR);
                    err_tropo_M = err_tropo_M(iM);
                    err_iono_M  = err_iono_M (iM);
                end

                %--------------------------------------------------------------------------------------------
                % SATELLITE CONFIGURATION SAVING AND PIVOT SELECTION
                %--------------------------------------------------------------------------------------------

                switch this.sol_type
                    case 0 % code and phase
                        sat_pr_track(sat_pr, 1) = 1;
                        sat_ph_track(sat_ph, 1) = 1;
                    case -1 % code only;
                        sat_pr_track(sat_pr, 1) = 1;
                    case 1 % phase only
                        sat_ph_track(sat_ph, 1) = 1;
                end

                %actual pivot
                [null_max_elR, pivot_index] = max(elR(sat_ph)); %#ok<ASGLU>
                pivot = sat_ph(pivot_index);

                %--------------------------------------------------------------------------------------------
                % PHASE CENTER VARIATIONS
                %--------------------------------------------------------------------------------------------

                %compute PCV: phase and code 1
                [~, index_ph]=intersect(sat_pr,sat_ph);

                if (~isempty(ant_pcv) && ant_pcv(2).n_frequency ~= 0) % master
                    index_master = 2;
                    PCO1_M = PCO_correction(ant_pcv(index_master), pos_r, XS, sys, 1);
                    PCV1_M = PCV_correction(ant_pcv(index_master), 90-elM(sat_pr), azM(sat_pr), sys, 1);
                    pr1_m(sat_pr) = pr1_m(sat_pr) - (PCO1_M + PCV1_M);
                    ph1_m(sat_ph)    = ph1_m(sat_ph)    - (PCO1_M(index_ph) + PCV1_M(index_ph))./lambda(sat_ph,1);

                    if (length(frequencies) == 2 || frequencies(1) == 2)
                        PCO2_M = PCO_correction(ant_pcv(index_master), pos_r, XS, sys, 2);
                        PCV2_M = PCV_correction(ant_pcv(index_master), 90-elM(sat_pr), azM(sat_pr), sys, 2);
                        pr2_m(sat_pr) = pr2_m(sat_pr) - (PCO2_M + PCV2_M);
                        ph2_m(sat_ph)    = ph2_m(sat_ph)    - (PCO2_M(index_ph) + PCV2_M(index_ph))./lambda(sat_ph,2);
                    end
                end

                if (~isempty(ant_pcv) && ant_pcv(1).n_frequency ~= 0) % rover
                    index_rover = 1;
                    PCO1_R = PCO_correction(ant_pcv(index_rover), pos_r, XS, sys, 1);
                    PCV1_R = PCV_correction(ant_pcv(index_rover), 90-elR(sat_pr), azR(sat_pr), sys, 1);
                    pr1_r(sat_pr) = pr1_r(sat_pr) - (PCO1_R + PCV1_R);
                    ph1_r(sat_ph)    = ph1_r(sat_ph)    - (PCO1_R(index_ph) + PCV1_R(index_ph))./lambda(sat_ph,1);

                    if (length(frequencies) == 2 || frequencies(1) == 2)
                        PCO1_R = PCO_correction(ant_pcv(index_rover), pos_r, XS, sys, 2);
                        PCV2_R = PCV_correction(ant_pcv(index_rover), 90-elM(sat_pr), azM(sat_pr), sys, 2);
                        pr2_r(sat_pr) = pr2_r(sat_pr) - (PCO1_R + PCV2_R);
                        ph2_r(sat_ph)    = ph2_r(sat_ph)    - (PCO1_R(index_ph) + PCV2_R(index_ph))./lambda(sat_ph,2);
                    end
                end

                %--------------------------------------------------------------------------------------------
                % PREPARE INPUT FOR LEAST SQUARES BATCH
                %--------------------------------------------------------------------------------------------

                %if at least min_nsat_LS satellites are available after the cutoffs, and if the
                % condition number in the least squares does not exceed the threshold
                if (size(sat_ph,1) >= min_nsat_LS && (isempty(cond_num) || cond_num < cond_n_threshold))

                    if (frequencies == 1)
                        [y0, A, b, Q] = this.oneEpochBuild(pos_r, pos_m, XS, pr1_r(sat_ph), ph1_r(sat_ph), snr_r(sat_ph), pr1_m(sat_ph), ph1_m(sat_ph), snr_m(sat_ph), elR(sat_ph), elM(sat_ph), err_tropo_R, err_iono_R, err_tropo_M, err_iono_M, pivot_index, lambda(sat_ph,1));
                    else
                        [y0, A, b, Q] = this.oneEpochBuild(pos_r, pos_m, XS, pr2_r(sat_ph), ph2_r(sat_ph), snr_r(sat_ph), pr2_m(sat_ph), ph2_m(sat_ph), snr_m(sat_ph), elR(sat_ph), elM(sat_ph), err_tropo_R, err_iono_R, err_tropo_M, err_iono_M, pivot_index, lambda(sat_ph,2));
                    end

                else
                    pivot = 0;
                end
            else
                pivot = 0;
            end
        end

        function [y0, A, b, Q] = oneEpochBuild ( this, ...
                   pos_r_approx, pos_m, pos_s, ...
                   pr_r, ph_r, snr_r, ...
                   pr_m, ph_m, snr_m, ...
                   el_r, el_m, ...
                   err_tropo_r, err_iono_r, ...
                   err_tropo_m, err_iono_m, pivot_id, lambda)

            % SYNTAX:
            %   [y0, A, b, Q] = this.oneEpochBuild (XR_approx, XM, XS, pr_R, ph_R, snr_R, pr_M, ph_M, snr_M, elR, elM, err_tropo_R, err_iono_R, err_tropo_M, err_iono_M, pivot_index, lambda);
            %
            % INPUT:
            %   XR_approx   = receiver approximate position (X,Y,Z)
            %   XM          = master station position (X,Y,Z)
            %   XS          = satellite position (X,Y,Z)
            %   pr_R        = receiver code observations
            %   ph_R        = receiver phase observations
            %   pr_M        = master code observations
            %   pr_M        = master phase observations
            %   snr_R       = receiversignal-to-noise ratio
            %   snr_M       = mastersignal-to-noise ratio
            %   elR         = satellite elevation (vector)
            %   elM         = satellite elevation (vector)
            %   err_tropo_R = tropospheric error
            %   err_tropo_M = tropospheric error
            %   err_iono_R  = ionospheric error
            %   err_iono_M  = ionospheric error
            %   pivot_index = index identifying the pivot satellite
            %   lambda      = vector containing GNSS wavelengths for available satellites
            %
            % OUTPUT:
            %   y0 = observation vector
            %   A = design matrix
            %   b = known term vector
            %   Q = observation covariance matrix
            %
            % DESCRIPTION:
            %   Function that prepares the input matrices for the least squares batch solution.

            % variable initialization
            global sigmaq_cod1 sigmaq_ph

            % number of observations
            n = length(pr_r);

            % approximate receiver-satellite distance
            XR_mat = pos_r_approx(:,ones(n,1))';
            XM_mat = pos_m(:,ones(n,1))';
            distR_approx = sqrt(sum((pos_s-XR_mat).^2 ,2));
            distM = sqrt(sum((pos_s-XM_mat).^2 ,2));

            % design matrix (code or phase)
            A = [((pos_r_approx(1) - pos_s(:,1)) ./ distR_approx) - ((pos_r_approx(1) - pos_s(pivot_id,1)) / distR_approx(pivot_id)), ... %column for X coordinate
                ((pos_r_approx(2) - pos_s(:,2)) ./ distR_approx) - ((pos_r_approx(2) - pos_s(pivot_id,2)) / distR_approx(pivot_id)), ... %column for Y coordinate
                ((pos_r_approx(3) - pos_s(:,3)) ./ distR_approx) - ((pos_r_approx(3) - pos_s(pivot_id,3)) / distR_approx(pivot_id))];    %column for Z coordinate

            % known term vector
            b    =     (distR_approx - distM)      - (distR_approx(pivot_id) - distM(pivot_id));       %approximate pseudorange DD
            b    = b + (err_tropo_r - err_tropo_m) - (err_tropo_r(pivot_id)  - err_tropo_m(pivot_id)); %tropospheric error DD

            if (this.sol_type <= 0)
                % known term vector
                b_pr = b + (err_iono_r  - err_iono_m)  - (err_iono_r(pivot_id)   - err_iono_m(pivot_id));  %ionoshperic error DD (code)
                % observation vector
                y0_pr = (pr_r - pr_m) - (pr_r(pivot_id) - pr_m(pivot_id));
                % remove pivot-pivot lines
                b_pr(pivot_id)    = [];
                y0_pr(pivot_id)   = [];
            end

            if (this.sol_type >= 0)
                % known term vector
                b_ph = b - (err_iono_r  - err_iono_m)  + (err_iono_r(pivot_id)   - err_iono_m(pivot_id));  %ionoshperic error DD (phase)
                % observation vector
                y0_ph = lambda.*((ph_r - ph_m) - (ph_r(pivot_id) - ph_m(pivot_id)));
                % remove pivot-pivot lines
                b_ph(pivot_id)    = [];
                y0_ph(pivot_id)   = [];
            end

            % remove pivot-pivot lines
            A(pivot_id, :) = [];

            % observation noise covariance matrix
            Q1 = cofactor_matrix(el_r, el_m, snr_r, snr_m, pivot_id);

            switch this.sol_type
                case 0 % code and phase
                    A = [A; A];
                    b = [b_pr; b_ph];
                    y0 = [y0_pr; y0_ph];
                    n = 2*n - 2;
                    Q = zeros(n);
                    Q(1:n/2,1:n/2) = sigmaq_cod1 * Q1;
                    Q(n/2+1:end,n/2+1:end) = sigmaq_ph * Q1;
                case -1 % code only;
                    b = b_pr;
                    y0 = y0_pr;
                    Q = sigmaq_cod1 * Q1;
                case 1 % phase only
                    b = b_ph;
                    y0 = y0_ph;
                    Q = sigmaq_ph * Q1;
            end
        end

        function id_track = computeIdTrack(this, A, obs_track, n_pos)
            if (nargin == 1)
                A = this.A;
                obs_track = this.obs_track;
                n_pos =  this.n_pos;
            end
            n_amb = size(A, 2) - n_pos * 3;
            n_tot_epoch = size(A,1);
            
            id_track = spalloc(n_tot_epoch, n_amb, round(n_tot_epoch * n_amb * 0.5));
            for a = 1 : n_amb
                idx = find(A(:, 3 + a) < 0);
                id_track(obs_track(idx, 1), a) = idx; %#ok<*SPRIX>
            end
        end
        
    end

    % ==================================================================================================================================================
    %  STATIC FUNCTIONS used as utilities goBlock
    % ==================================================================================================================================================
    methods (Static, Access = private)
                    
        function [col_ok, ref_arc] = getBestRefArc(y0, b, A, Q)
            % compute multiple LS solutions changing the reference arc fort the LS and get the best
            % SYNTAX: id_min = refineRefArc(y0, b, A, Q)
            amb_num = size(A,2) - 3;
            P = []; N = [];
            if (amb_num > 1)
                test = zeros(amb_num, 1);
                for i = 4 : size(A,2)
                    col_ok = setdiff(1:size(A,2), i);
                    [x, Cxx, s02, v_hat, P, N] = Core_Block.solveLS(y0, b, A, col_ok, Q, P, N);
                    amb_var = Cxx(4:end,4:end);
                    amb_var(amb_var < 0) = 1e30;
                    test(i-3) = sum(diag(amb_var));
                end
                [~, ref_arc] = sort(test);
                ref_arc = ref_arc(1);
            else
                ref_arc = [];
            end
            col_ok = setdiff(1:size(A,2), ref_arc + 3);
        end
        
        function [col_ok, ref_arc, bad_blocks] = getBestBlockRefArc(y0, b, A, Q, ref_arc, bad_arc, bad_blocks, blk_cols)
            % compute multiple LS solutions changing the reference arc fort the LS and get the best
            % SYNTAX: [col_ok, ref_arc] = this.getBestBlockRefArc(y0, b, A, Q, ref_arc, bad_arc, blk_cols)
            
            if isempty(bad_blocks)
                bad_blocks = find(ismember(ref_arc, bad_arc));
            end
            for bb = 1 : numel(bad_blocks)
                bad_block = bad_blocks(bb);
                if ~isempty(bad_block)
                    ref_arc(bad_block) = 0;
                    
                    amb_num = sum(blk_cols(4 : end, bad_block));
                    if (amb_num > 1)
                        test = ones(size(A, 2) - 3, 1) * 1e30;
                        block_arc = setdiff(find(blk_cols(4 : end, bad_block)), bad_arc);
                        for i = 1 : numel(block_arc)
                            col_ok = setdiff(1:size(A,2), [ref_arc + 3; block_arc(i) + 3]);
                            [~, Cxx, ~, ~] = fast_least_squares_solver(y0, b, A(:, col_ok), Q);
                            amb_var = Cxx(4:end,4:end);
                            amb_var(amb_var < 0) = 1e30;
                            test(block_arc(i)) = sum(diag(amb_var));
                        end
                        [~, tmp] = sort(test);
                        tmp = tmp(1);
                    else
                        tmp = [];
                    end
                    ref_arc(bad_block) = tmp;
                end
            end
            col_ok = setdiff(1:size(A,2), ref_arc + 3);
        end
        
        function [y0, b, A, col_ok, ref_arc, Q, v_hat, obs_track, amb_prn_track] = rejectBlockOutliers(this, y0, b, A, col_ok, Q, v_hat, obs_track, amb_prn_track)
        end
        
        function [pos, pos_cov] = applyFix(x_float, Cxx, amb_fix, G)
            % Apply a fix for the ambiguities
            % SYNTAX: [pos, pos_cov] = applyFix(x_float, Cxx, amb_fix, G)
            n_amb = numel(amb_fix);
            n_pos = (size(x_float, 1) - 1 - n_amb) / 3;
            if (nargin >= 4)
                if size(G, 1) < (n_pos * 3 + n_amb)
                    G_multipos = eye((n_pos * 3 + n_amb), (n_pos * 3 + n_amb) + 1);
                    G_multipos((n_pos - 1) * 3 + 1 : end, (n_pos - 1) * 3 +1 : end) = G;
                else
                    G_multipos = G;
                end
                x_float = G_multipos * x_float;
                Cxx = full(G_multipos * Cxx * G_multipos');
            end
            
            cov_pos  = Cxx(1 : 3 * n_pos, 1 : 3 * n_pos);     % position covariance block
            cov_amb  = Cxx(3 * n_pos + 1 : end, 3 * n_pos + 1 : end); % ambiguity covariance block
            cov_cross = Cxx(1 : 3 * n_pos, 3 * n_pos + 1 : end);   % position-ambiguity covariance block
            
            try
                % stabilize cov_N;
                [U] = chol(cov_amb);
                cov_amb = U'*U;
                pos = reshape(x_float(1 : n_pos * 3) - cov_cross * cholinv(cov_amb) * (x_float(3 * n_pos + 1 : end) - amb_fix(:, 1)), 3, n_pos);
                pos_cov = cov_pos  - cov_cross * cholinv(cov_amb) * cov_cross';
            catch ex
                logger = Logger.getInstance();
                logger.addWarning(sprintf('Phase ambiguities covariance matrix unstable - %s', ex.message));
                pos = reshape(x_float(1 : n_pos * 3) - cov_cross * (cov_amb)^-1 * (x_float(3 * n_pos + 1 : end) - amb_fix(:, 1)), 3, n_pos);
                pos_cov = cov_pos  - cov_cross * (cov_amb)^-1 * cov_cross';
            end
        end

        function [A, y0, b, Q, obs_track, amb_prn_track, rem_amb] = remShortArc (A, y0, b, Q, obs_track, amb_prn_track, min_arc)
            % Remove ambiguity unkowns with arcs shorter than given threshold
            % SYNTAX: [A, y0, b, Q, obs_track, amb_prn_track, rem_amb] = this.remShortArc(A, y0, b, Q, obs_track, amb_prn_track, min_arc)
            
            amb_num = numel(amb_prn_track);
            pos_num = size(A,2) - amb_num;
            rem_amb = setdiff(find(sum(A~=0,1) < min_arc), 1 : pos_num);
            
            if (~isempty(rem_amb))
                rem_obs = [];
                for r = 1 : length(rem_amb)
                    rem_obs = [rem_obs; find(A(:,rem_amb(r))~=0)]; %#ok<AGROW>
                end
                A(rem_obs,:) = [];
                y0(rem_obs) = [];
                b(rem_obs) = [];
                Q(rem_obs,:) = []; Q(:,rem_obs) = [];
                obs_track(rem_obs,:) = [];
                
                A(:,rem_amb) = [];
                amb_prn_track(rem_amb - pos_num) = [];
            end
        end
        
        function [A, y0, b, Q, obs_track, amb_prn_track] = remArcCol (A, y0, b, Q, obs_track, amb_prn_track, rem_amb)
            % remove one arc from the LS system
            % SYNTAX: [A, y0, b, Q, obs_track, amb_prn_track] = remArcCol(A, y0, b, Q, obs_track, amb_prn_track, rem_amb)
            if (~isempty(rem_amb))
                rem_obs = [];
                for r = 1 : length(rem_amb)
                    rem_obs = [rem_obs; find(A(:,rem_amb(r))~=0)]; %#ok<AGROW>
                end
                A(rem_obs,:) = [];
                y0(rem_obs) = [];
                b(rem_obs) = [];
                Q(rem_obs,:) = []; Q(:,rem_obs) = [];
                obs_track(rem_obs,:) = [];

                A(:,rem_amb) = [];
                amb_prn_track(rem_amb-3) = [];
            end
        end

        function [id_out] = findBadObs (phase_res, thr, win_size)
            % find obs far from a median solution (not currently used)
            % SYNTAX: [id_out] = findBadObs(phase_res, thr, win_size)
            id_out = [];
            for a = 1 : size(phase_res, 2)
                y = phase_res(:, a, 1);
                if nargin == 3
                    mm = medfilt_mat(y(~isnan(y)), win_size);
                else
                    mm = 0;
                end

                e_sup = y; e_sup(~isnan(y)) = mm + thr;
                e_inf = y; e_inf(~isnan(y)) = mm - thr;

                id_out = [id_out; (a-1) * size(phase_res, 1) + find(y > e_sup | y < e_inf)]; %#ok<AGROW>
            end
        end

        function [A, amb_prn_track]  = splitArcs (A, obs_track, amb_prn_track)

            amb_num = numel(amb_prn_track);

            idx_ph = (obs_track(:,3) == 1);

            for a = 1 : amb_num
                % find obs of an arc
                id_obs_ok = find(full(idx_ph & (A(:,3 + a) < 0)));
                % find the epochs of these obs
                id_epoch_ok = zeros(max(obs_track(:,1)),1);
                id_epoch_ok(obs_track(id_obs_ok)) = id_obs_ok;
                [lim] = getOutliers(id_epoch_ok);
                for i = 2 : size(lim,1)
                    new_col = zeros(size(A,1),1);
                    new_col(lim(i,1) : lim(i,2)) = A(lim(i,1) : lim(i,2), 3 + a);
                    amb_prn_track = [amb_prn_track; amb_prn_track(a)]; %#ok<AGROW>
                    A(lim(i,1) : lim(i,2), 3 + a) = 0;
                    A = [A new_col]; %#ok<AGROW>
                end
            end
        end
        
    end

end

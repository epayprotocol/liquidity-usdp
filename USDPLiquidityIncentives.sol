// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Treasury interface for reward funding
interface ITreasury {
    function getCollateralValue() external view returns (uint256);
    function hasAvailableCollateral(uint256 amount) external view returns (bool);
    function requestCollateralBacking(uint256 amount) external returns (bool);
    function deployStabilityFunds(uint256 amount, address recipient) external;
    function replenishStabilityFund(uint256 amount) external;
}

/// @dev Governance interface for parameter control
interface IGovernance {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function executeProposal(uint256 proposalId) external;
}

/// @dev Oracle interface for price and volume data
interface IOracle {
    function latestAnswer() external view returns (uint256);
    function getVolumeData(address pair) external view returns (uint256, uint256);
    function getPriceStability(address pair, uint256 timeframe) external view returns (uint256);
}

/// @dev LP Token interface for DEX integration
interface ILPToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @title USDP Liquidity Incentives Contract
/// @notice Comprehensive liquidity incentive system for USDP ecosystem
/// @dev Manages LP staking, market maker incentives, and dynamic reward distribution
contract USDPLiquidityIncentives {

    /*//////////////////////////////////////////////////////////////
                            REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/
    
    uint256 private _status = 1;
    
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP
    //////////////////////////////////////////////////////////////*/
    
    address public owner;
    address public pendingOwner;
    
    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORIZED");
        _;
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "INVALID_OWNER");
        pendingOwner = newOwner;
    }
    
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING_OWNER");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }
    
    /*//////////////////////////////////////////////////////////////
                            SAFE ERC20 TRANSFER
    //////////////////////////////////////////////////////////////*/
    
    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }
    
    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DECIMALS = 18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Staking duration tiers
    uint256 public constant TIER_1_DURATION = 1 weeks;
    uint256 public constant TIER_2_DURATION = 4 weeks;
    uint256 public constant TIER_3_DURATION = 12 weeks;
    
    // Reward multipliers (in basis points)
    uint256 public constant TIER_1_MULTIPLIER = 10000;  // 1x
    uint256 public constant TIER_2_MULTIPLIER = 15000;  // 1.5x
    uint256 public constant TIER_3_MULTIPLIER = 20000;  // 2x
    
    // Default parameters
    uint256 public constant DEFAULT_BASE_APY = 1500;    // 15%
    uint256 public constant MAX_APY = 10000;            // 100%
    uint256 public constant MIN_STAKE_AMOUNT = 1e18;    // 1 token minimum
    uint256 public constant BOOTSTRAP_MULTIPLIER = 20000; // 2x for bootstrap period

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/
    
    struct PoolInfo {
        address lpToken;           // LP token contract address
        address dex;              // DEX contract address (PancakeSwap, BiSwap, etc.)
        uint256 allocPoint;       // Allocation points for this pool
        uint256 lastRewardTime;   // Last time rewards were calculated
        uint256 accRewardPerShare; // Accumulated rewards per share
        uint256 totalStaked;      // Total LP tokens staked in pool
        uint256 baseAPY;          // Base APY for this pool (in BP)
        uint256 volumeMultiplier; // Volume-based multiplier (in BP)
        bool isActive;            // Pool status
        bool isBootstrap;         // Bootstrap period status
    }
    
    struct UserInfo {
        uint256 amount;           // Amount of LP tokens staked
        uint256 rewardDebt;       // Reward debt for accurate reward calculation
        uint256 stakingStartTime; // When user started staking
        uint256 lockEndTime;      // When lock period ends
        uint256 tierMultiplier;   // User's tier multiplier
        uint256 pendingRewards;   // Unclaimed rewards
        uint256 totalEarned;      // Total rewards earned lifetime
        uint256 lastClaimTime;    // Last reward claim timestamp
    }
    
    struct MarketMakerInfo {
        bool isActive;            // Market maker status
        uint256 volumeTarget;     // Required trading volume
        uint256 spreadTarget;     // Maximum allowed spread (in BP)
        uint256 rebateRate;       // Fee rebate percentage (in BP)
        uint256 totalVolume;      // Total volume generated
        uint256 totalRebates;     // Total rebates earned
        uint256 lastActivity;     // Last trading activity timestamp
        uint256 gasSubsidy;       // Gas fee subsidies earned
    }
    
    struct RewardConfig {
        uint256 emissionRate;     // Rewards per second
        uint256 totalEmissions;   // Total rewards to distribute
        uint256 emittedRewards;   // Total rewards already emitted
        uint256 bootstrapEnd;     // End of bootstrap period
        uint256 halvingInterval;  // Emission halving interval
        uint256 lastHalving;      // Last halving timestamp
    }
    
    struct VolumeData {
        uint256 dailyVolume;      // 24h trading volume
        uint256 weeklyVolume;     // 7d trading volume
        uint256 monthlyVolume;    // 30d trading volume
        uint256 lastUpdateTime;   // Last volume update
        uint256 priceStability;   // Price stability score (0-10000)
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    
    // Core contracts
    IERC20 public immutable usdpToken;
    IERC20 public immutable rewardToken;  // Could be USDP or separate governance token
    ITreasury public treasury;
    IGovernance public governance;
    IOracle public oracle;
    
    // Pool management
    PoolInfo[] public pools;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => uint256) public lpTokenToPoolId;
    mapping(address => bool) public supportedDEXs;
    
    // Market maker management
    mapping(address => MarketMakerInfo) public marketMakers;
    mapping(address => mapping(uint256 => uint256)) public dailyVolume; // MM => day => volume
    address[] public marketMakerList;
    
    // Reward configuration
    RewardConfig public rewardConfig;
    mapping(uint256 => VolumeData) public poolVolumeData; // poolId => volume data
    
    // Global settings
    uint256 public totalAllocPoint;
    uint256 public startTime;
    uint256 public totalStaked;
    uint256 public totalRewardsDistributed;
    
    // Security and access control
    mapping(address => bool) public authorizedUpdaters;
    mapping(address => bool) public emergencyGuardians;
    bool public emergencyPaused;
    bool public stakingEnabled = true;
    bool public claimingEnabled = true;
    
    // Anti-gaming measures
    mapping(address => uint256) public lastStakeTime;
    mapping(address => uint256) public userNonce;
    uint256 public minStakingInterval = 1 hours;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event PoolAdded(uint256 indexed poolId, address indexed lpToken, address indexed dex, uint256 allocPoint);
    event PoolUpdated(uint256 indexed poolId, uint256 allocPoint, uint256 baseAPY);
    event Staked(address indexed user, uint256 indexed poolId, uint256 amount, uint256 lockDuration);
    event Unstaked(address indexed user, uint256 indexed poolId, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event CompoundStaking(address indexed user, uint256 indexed poolId, uint256 rewardAmount);
    
    event MarketMakerAdded(address indexed marketMaker, uint256 volumeTarget, uint256 rebateRate);
    event MarketMakerRemoved(address indexed marketMaker);
    event RebatePaid(address indexed marketMaker, uint256 amount, uint256 volume);
    event GasSubsidyPaid(address indexed marketMaker, uint256 amount);
    
    event VolumeUpdated(uint256 indexed poolId, uint256 dailyVolume, uint256 priceStability);
    event APYUpdated(uint256 indexed poolId, uint256 newAPY, uint256 volumeMultiplier);
    event EmissionRateUpdated(uint256 newRate, uint256 totalEmissions);
    event BootstrapPeriodEnded(uint256 timestamp);
    
    event EmergencyPaused(uint256 timestamp);
    event EmergencyUnpaused(uint256 timestamp);
    event TreasuryFundingReceived(uint256 amount);
    event RewardTokensRecovered(address indexed token, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error InvalidPool();
    error InsufficientStake();
    error StillLocked();
    error EmergencyPausedError();
    error UnauthorizedAccess();
    error InvalidParameters();
    error InsufficientRewards();
    error MarketMakerNotActive();
    error StakingTooFrequent();
    error InvalidLockDuration();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    
    modifier onlyAuthorized() {
        require(authorizedUpdaters[msg.sender] || msg.sender == owner, "UNAUTHORIZED");
        _;
    }
    
    modifier onlyEmergencyGuardian() {
        require(emergencyGuardians[msg.sender] || msg.sender == owner, "UNAUTHORIZED_GUARDIAN");
        _;
    }
    
    modifier onlyGovernance() {
        require(address(governance) != address(0) && msg.sender == address(governance), "UNAUTHORIZED_GOVERNANCE");
        _;
    }
    
    modifier whenNotPaused() {
        require(!emergencyPaused, "EMERGENCY_PAUSED");
        _;
    }
    
    modifier validPool(uint256 poolId) {
        require(poolId < pools.length, "INVALID_POOL");
        require(pools[poolId].isActive, "POOL_INACTIVE");
        _;
    }
    
    modifier activeMarketMaker(address marketMaker) {
        require(marketMakers[marketMaker].isActive, "MARKET_MAKER_INACTIVE");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    
    constructor(
        address _usdpToken,
        address _rewardToken,
        address _treasury,
        address _governance,
        address _oracle,
        uint256 _startTime
    ) {
        require(_usdpToken != address(0), "INVALID_USDP_TOKEN");
        require(_rewardToken != address(0), "INVALID_REWARD_TOKEN");
        require(_treasury != address(0), "INVALID_TREASURY");
        require(_startTime > block.timestamp, "INVALID_START_TIME");
        
        usdpToken = IERC20(_usdpToken);
        rewardToken = IERC20(_rewardToken);
        treasury = ITreasury(_treasury);
        governance = IGovernance(_governance);
        oracle = IOracle(_oracle);
        startTime = _startTime;
        
        // Initialize reward configuration
        rewardConfig = RewardConfig({
            emissionRate: 1e18, // 1 token per second initially
            totalEmissions: 1000000e18, // 1M tokens total
            emittedRewards: 0,
            bootstrapEnd: _startTime + 90 days, // 3 month bootstrap
            halvingInterval: 180 days, // 6 month halving
            lastHalving: _startTime
        });
        
        // Set initial authorized addresses
        authorizedUpdaters[msg.sender] = true;
        emergencyGuardians[msg.sender] = true;
    }

    /*//////////////////////////////////////////////////////////////
                            POOL MANAGEMENT
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Add a new LP token pool for staking
    /// @param _lpToken LP token contract address
    /// @param _dex DEX contract address
    /// @param _allocPoint Allocation points for reward distribution
    /// @param _baseAPY Base APY for the pool (in basis points)
    function addPool(
        address _lpToken,
        address _dex,
        uint256 _allocPoint,
        uint256 _baseAPY
    ) external onlyAuthorized {
        require(_lpToken != address(0), "INVALID_LP_TOKEN");
        require(_dex != address(0), "INVALID_DEX");
        require(_baseAPY <= MAX_APY, "APY_TOO_HIGH");
        require(lpTokenToPoolId[_lpToken] == 0 && (pools.length == 0 || pools[0].lpToken != _lpToken), "POOL_EXISTS");
        
        // Verify LP token contains USDP
        ILPToken lpToken = ILPToken(_lpToken);
        require(
            lpToken.token0() == address(usdpToken) || lpToken.token1() == address(usdpToken),
            "LP_TOKEN_MUST_CONTAIN_USDP"
        );
        
        totalAllocPoint += _allocPoint;
        
        pools.push(PoolInfo({
            lpToken: _lpToken,
            dex: _dex,
            allocPoint: _allocPoint,
            lastRewardTime: block.timestamp > startTime ? block.timestamp : startTime,
            accRewardPerShare: 0,
            totalStaked: 0,
            baseAPY: _baseAPY,
            volumeMultiplier: BASIS_POINTS, // 1x initially
            isActive: true,
            isBootstrap: block.timestamp < rewardConfig.bootstrapEnd
        }));
        
        uint256 poolId = pools.length - 1;
        lpTokenToPoolId[_lpToken] = poolId;
        supportedDEXs[_dex] = true;
        
        emit PoolAdded(poolId, _lpToken, _dex, _allocPoint);
    }
    
    /// @notice Update pool allocation points and base APY
    /// @param _poolId Pool identifier
    /// @param _allocPoint New allocation points
    /// @param _baseAPY New base APY (in basis points)
    function updatePool(
        uint256 _poolId,
        uint256 _allocPoint,
        uint256 _baseAPY
    ) external validPool(_poolId) onlyAuthorized {
        require(_baseAPY <= MAX_APY, "APY_TOO_HIGH");
        
        _updatePool(_poolId);
        
        totalAllocPoint = totalAllocPoint - pools[_poolId].allocPoint + _allocPoint;
        pools[_poolId].allocPoint = _allocPoint;
        pools[_poolId].baseAPY = _baseAPY;
        
        emit PoolUpdated(_poolId, _allocPoint, _baseAPY);
    }
    
    /// @notice Update pool rewards and accumulate per share
    /// @param _poolId Pool to update
    function _updatePool(uint256 _poolId) internal {
        PoolInfo storage pool = pools[_poolId];
        
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        
        if (pool.totalStaked == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        
        uint256 timeElapsed = block.timestamp - pool.lastRewardTime;
        uint256 reward = calculatePoolReward(_poolId, timeElapsed);
        
        if (reward > 0) {
            pool.accRewardPerShare += (reward * 1e12) / pool.totalStaked;
            rewardConfig.emittedRewards += reward;
        }
        
        pool.lastRewardTime = block.timestamp;
    }
    
    /// @notice Calculate pool reward for given time period
    /// @param _poolId Pool identifier
    /// @param _timeElapsed Time period in seconds
    /// @return reward Calculated reward amount
    function calculatePoolReward(uint256 _poolId, uint256 _timeElapsed) public view returns (uint256 reward) {
        PoolInfo storage pool = pools[_poolId];
        
        if (totalAllocPoint == 0) return 0;
        
        // Base emission rate
        uint256 currentEmissionRate = getCurrentEmissionRate();
        uint256 poolShare = (pool.allocPoint * 1e18) / totalAllocPoint;
        uint256 baseReward = (currentEmissionRate * _timeElapsed * poolShare) / 1e18;
        
        // Apply bootstrap multiplier if applicable
        if (pool.isBootstrap && block.timestamp < rewardConfig.bootstrapEnd) {
            baseReward = (baseReward * BOOTSTRAP_MULTIPLIER) / BASIS_POINTS;
        }
        
        // Apply volume multiplier
        reward = (baseReward * pool.volumeMultiplier) / BASIS_POINTS;
        
        // Ensure we don't exceed total emissions
        if (rewardConfig.emittedRewards + reward > rewardConfig.totalEmissions) {
            reward = rewardConfig.totalEmissions - rewardConfig.emittedRewards;
        }
        
        return reward;
    }
    
    /// @notice Get current emission rate considering halvings
    /// @return Current emission rate per second
    function getCurrentEmissionRate() public view returns (uint256) {
        uint256 halvings = (block.timestamp - rewardConfig.lastHalving) / rewardConfig.halvingInterval;
        uint256 currentRate = rewardConfig.emissionRate;
        
        for (uint256 i = 0; i < halvings; i++) {
            currentRate = currentRate / 2;
        }
        
        return currentRate;
    }

    /*//////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Stake LP tokens in a pool
    /// @param _poolId Pool to stake in
    /// @param _amount Amount of LP tokens to stake
    /// @param _lockDuration Lock duration (0 for no lock, 1/2/3 for tiers)
    function stakeLPTokens(
        uint256 _poolId,
        uint256 _amount,
        uint256 _lockDuration
    ) external validPool(_poolId) whenNotPaused nonReentrant {
        require(stakingEnabled, "STAKING_DISABLED");
        require(_amount >= MIN_STAKE_AMOUNT, "INSUFFICIENT_AMOUNT");
        require(_lockDuration <= 3, "INVALID_LOCK_DURATION");
        require(
            block.timestamp >= lastStakeTime[msg.sender] + minStakingInterval,
            "STAKING_TOO_FREQUENT"
        );
        
        PoolInfo storage pool = pools[_poolId];
        UserInfo storage user = userInfo[_poolId][msg.sender];
        
        _updatePool(_poolId);
        
        // Claim any pending rewards first
        if (user.amount > 0) {
            uint256 pending = ((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }
        
        // Transfer LP tokens
        _safeTransferFrom(IERC20(pool.lpToken), msg.sender, address(this), _amount);
        
        // Update user info
        user.amount += _amount;
        user.stakingStartTime = block.timestamp;
        user.tierMultiplier = _getTierMultiplier(_lockDuration);
        
        if (_lockDuration == 1) {
            user.lockEndTime = block.timestamp + TIER_1_DURATION;
        } else if (_lockDuration == 2) {
            user.lockEndTime = block.timestamp + TIER_2_DURATION;
        } else if (_lockDuration == 3) {
            user.lockEndTime = block.timestamp + TIER_3_DURATION;
        }
        
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        
        // Update pool stats
        pool.totalStaked += _amount;
        totalStaked += _amount;
        lastStakeTime[msg.sender] = block.timestamp;
        
        emit Staked(msg.sender, _poolId, _amount, _lockDuration);
    }
    
    /// @notice Unstake LP tokens from a pool
    /// @param _poolId Pool to unstake from
    /// @param _amount Amount to unstake
    function unstakeLPTokens(
        uint256 _poolId,
        uint256 _amount
    ) external validPool(_poolId) whenNotPaused nonReentrant {
        UserInfo storage user = userInfo[_poolId][msg.sender];
        require(user.amount >= _amount, "INSUFFICIENT_STAKED");
        require(block.timestamp >= user.lockEndTime, "STILL_LOCKED");
        
        PoolInfo storage pool = pools[_poolId];
        
        _updatePool(_poolId);
        
        // Calculate and add pending rewards
        uint256 pending = ((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }
        
        // Update user info
        user.amount -= _amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        
        // Update pool stats
        pool.totalStaked -= _amount;
        totalStaked -= _amount;
        
        // Transfer LP tokens back
        _safeTransfer(IERC20(pool.lpToken), msg.sender, _amount);
        
        emit Unstaked(msg.sender, _poolId, _amount);
    }
    
    /// @notice Claim rewards from a pool
    /// @param _poolId Pool to claim from
    function claimRewards(uint256 _poolId) external validPool(_poolId) whenNotPaused nonReentrant {
        require(claimingEnabled, "CLAIMING_DISABLED");
        
        UserInfo storage user = userInfo[_poolId][msg.sender];
        PoolInfo storage pool = pools[_poolId];
        
        _updatePool(_poolId);
        
        // Calculate total rewards
        uint256 pending = ((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt;
        uint256 totalRewards = user.pendingRewards + pending;
        
        require(totalRewards > 0, "NO_REWARDS");
        
        // Apply tier multiplier
        totalRewards = (totalRewards * user.tierMultiplier) / BASIS_POINTS;
        
        // Reset pending rewards
        user.pendingRewards = 0;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        user.totalEarned += totalRewards;
        user.lastClaimTime = block.timestamp;
        
        // Update global stats
        totalRewardsDistributed += totalRewards;
        
        // Transfer rewards
        _safeTransfer(rewardToken, msg.sender, totalRewards);
        
        emit RewardsClaimed(msg.sender, _poolId, totalRewards);
    }
    
    /// @notice Compound rewards by staking them (if reward token is stakeable)
    /// @param _poolId Pool to compound in
    function compoundRewards(uint256 _poolId) external validPool(_poolId) whenNotPaused {
        // This function would auto-stake rewards if the reward token can be staked
        // Implementation depends on reward token mechanics
        revert("NOT_IMPLEMENTED"); // Placeholder
    }
    
    /// @notice Get tier multiplier based on lock duration
    /// @param _lockDuration Lock duration tier (1, 2, or 3)
    /// @return Tier multiplier in basis points
    function _getTierMultiplier(uint256 _lockDuration) internal pure returns (uint256) {
        if (_lockDuration == 1) return TIER_1_MULTIPLIER;
        if (_lockDuration == 2) return TIER_2_MULTIPLIER;
        if (_lockDuration == 3) return TIER_3_MULTIPLIER;
        return BASIS_POINTS; // No lock = 1x multiplier
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET MAKER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Add a new market maker
    /// @param _marketMaker Market maker address
    /// @param _volumeTarget Required trading volume
    /// @param _spreadTarget Maximum allowed spread (in BP)
    /// @param _rebateRate Fee rebate percentage (in BP)
    function addMarketMaker(
        address _marketMaker,
        uint256 _volumeTarget,
        uint256 _spreadTarget,
        uint256 _rebateRate
    ) external onlyAuthorized {
        require(_marketMaker != address(0), "INVALID_MARKET_MAKER");
        require(_rebateRate <= BASIS_POINTS, "INVALID_REBATE_RATE");
        require(!marketMakers[_marketMaker].isActive, "MARKET_MAKER_EXISTS");
        
        marketMakers[_marketMaker] = MarketMakerInfo({
            isActive: true,
            volumeTarget: _volumeTarget,
            spreadTarget: _spreadTarget,
            rebateRate: _rebateRate,
            totalVolume: 0,
            totalRebates: 0,
            lastActivity: block.timestamp,
            gasSubsidy: 0
        });
        
        marketMakerList.push(_marketMaker);
        
        emit MarketMakerAdded(_marketMaker, _volumeTarget, _rebateRate);
    }
    
    /// @notice Remove a market maker
    /// @param _marketMaker Market maker to remove
    function removeMarketMaker(address _marketMaker) external onlyAuthorized {
        require(marketMakers[_marketMaker].isActive, "MARKET_MAKER_NOT_ACTIVE");
        
        marketMakers[_marketMaker].isActive = false;
        
        // Remove from list
        for (uint256 i = 0; i < marketMakerList.length; i++) {
            if (marketMakerList[i] == _marketMaker) {
                marketMakerList[i] = marketMakerList[marketMakerList.length - 1];
                marketMakerList.pop();
                break;
            }
        }
        
        emit MarketMakerRemoved(_marketMaker);
    }
    
    /// @notice Process market maker rebate for trading volume
    /// @param _marketMaker Market maker address
    /// @param _volume Trading volume for rebate calculation
    /// @param _fees Total fees generated
    function processMarketMakerRebate(
        address _marketMaker,
        uint256 _volume,
        uint256 _fees
    ) external activeMarketMaker(_marketMaker) onlyAuthorized {
        MarketMakerInfo storage mm = marketMakers[_marketMaker];
        
        // Calculate rebate amount
        uint256 rebateAmount = (_fees * mm.rebateRate) / BASIS_POINTS;
        
        // Update market maker stats
        mm.totalVolume += _volume;
        mm.totalRebates += rebateAmount;
        mm.lastActivity = block.timestamp;
        
        // Update daily volume tracking
        uint256 currentDay = block.timestamp / 1 days;
        dailyVolume[_marketMaker][currentDay] += _volume;
        
        // Transfer rebate (from treasury)
        if (rebateAmount > 0) {
            try treasury.deployStabilityFunds(rebateAmount, _marketMaker) {
                // Success
            } catch {
                // Handle treasury failure gracefully
                revert("TREASURY_REBATE_FAILED");
            }
        }
        
        emit RebatePaid(_marketMaker, rebateAmount, _volume);
    }
    
    /// @notice Provide gas subsidy to market maker
    /// @param _marketMaker Market maker address
    /// @param _gasAmount Gas amount to subsidize
    function provideGasSubsidy(
        address _marketMaker,
        uint256 _gasAmount
    ) external activeMarketMaker(_marketMaker) onlyAuthorized {
        MarketMakerInfo storage mm = marketMakers[_marketMaker];
        
        // Calculate subsidy in tokens (simplified - would need gas price oracle)
        uint256 subsidyAmount = _gasAmount * 2e9; // Approximate gas price conversion
        
        mm.gasSubsidy += subsidyAmount;
        
        // Transfer subsidy
        try treasury.deployStabilityFunds(subsidyAmount, _marketMaker) {
            // Success
        } catch {
            // Handle treasury failure gracefully
            revert("TREASURY_SUBSIDY_FAILED");
        }
        
        emit GasSubsidyPaid(_marketMaker, subsidyAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        VOLUME & PRICE TRACKING
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Update volume data for a pool
    /// @param _poolId Pool identifier
    /// @param _dailyVolume 24h trading volume
    /// @param _priceStability Price stability score (0-10000)
    function updateVolumeData(
        uint256 _poolId,
        uint256 _dailyVolume,
        uint256 _priceStability
    ) external validPool(_poolId) onlyAuthorized {
        VolumeData storage volumeData = poolVolumeData[_poolId];
        
        // Update volume data
        volumeData.dailyVolume = _dailyVolume;
        volumeData.priceStability = _priceStability;
        volumeData.lastUpdateTime = block.timestamp;
        
        // Calculate volume multiplier
        uint256 volumeMultiplier = _calculateVolumeMultiplier(_poolId, _dailyVolume, _priceStability);
        pools[_poolId].volumeMultiplier = volumeMultiplier;
        
        // Calculate dynamic APY
        uint256 newAPY = _calculateDynamicAPY(_poolId);
        pools[_poolId].baseAPY = newAPY;
        
        emit VolumeUpdated(_poolId, _dailyVolume, _priceStability);
        emit APYUpdated(_poolId, newAPY, volumeMultiplier);
    }
    
    /// @notice Calculate volume-based multiplier
    /// @param _poolId Pool identifier
    /// @param _volume Trading volume
    /// @param _stability Price stability score
    /// @return Volume multiplier in basis points
    function _calculateVolumeMultiplier(
        uint256 _poolId,
        uint256 _volume,
        uint256 _stability
    ) internal view returns (uint256) {
        // Base multiplier starts at 1x
        uint256 multiplier = BASIS_POINTS;
        
        // Volume bonus: +0.1% per $100k volume (simplified)
        uint256 volumeBonus = (_volume / 100000e18) * 10; // 10 BP per 100k
        multiplier += volumeBonus;
        
        // Stability bonus: +0.5% for high stability (>9000/10000)
        if (_stability > 9000) {
            multiplier += 50; // 0.5% bonus
        }
        
        // Cap at 3x multiplier
        if (multiplier > 30000) {
            multiplier = 30000;
        }
        
        return multiplier;
    }
    
    /// @notice Calculate dynamic APY based on protocol metrics
    /// @param _poolId Pool identifier
    /// @return Dynamic APY in basis points
    function _calculateDynamicAPY(uint256 _poolId) internal view returns (uint256) {
        PoolInfo storage pool = pools[_poolId];
        
        // Start with base APY
        uint256 dynamicAPY = pool.baseAPY;
        
        // Adjust based on total value locked
        uint256 tvl = pool.totalStaked; // Simplified - would need price conversion
        if (tvl < 1000000e18) { // Less than 1M TVL gets boost
            dynamicAPY += 500; // +5% APY
        }
        
        // Adjust based on protocol revenue (would integrate with treasury)
        // This is simplified - real implementation would check treasury revenue
        
        // Cap at maximum APY
        if (dynamicAPY > MAX_APY) {
            dynamicAPY = MAX_APY;
        }
        
        return dynamicAPY;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Get pending rewards for a user in a pool
    /// @param _poolId Pool identifier
    /// @param _user User address
    /// @return Pending reward amount
    function pendingRewards(uint256 _poolId, address _user) external view returns (uint256) {
        if (_poolId >= pools.length) return 0;
        
        PoolInfo storage pool = pools[_poolId];
        UserInfo storage user = userInfo[_poolId][_user];
        
        uint256 accRewardPerShare = pool.accRewardPerShare;
        
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastRewardTime;
            uint256 reward = calculatePoolReward(_poolId, timeElapsed);
            accRewardPerShare += (reward * 1e12) / pool.totalStaked;
        }
        
        uint256 pending = ((user.amount * accRewardPerShare) / 1e12) - user.rewardDebt;
        uint256 totalRewards = user.pendingRewards + pending;
        
        // Apply tier multiplier
        return (totalRewards * user.tierMultiplier) / BASIS_POINTS;
    }
    
    /// @notice Get pool information
    /// @param _poolId Pool identifier
    /// @return Pool information struct
    function getPoolInfo(uint256 _poolId) external view returns (PoolInfo memory) {
        require(_poolId < pools.length, "INVALID_POOL");
        return pools[_poolId];
    }
    
    /// @notice Get user information for a pool
    /// @param _poolId Pool identifier
    /// @param _user User address
    /// @return User information struct
    function getUserInfo(uint256 _poolId, address _user) external view returns (UserInfo memory) {
        return userInfo[_poolId][_user];
    }
    
    /// @notice Get market maker information
    /// @param _marketMaker Market maker address
    /// @return Market maker information struct
    function getMarketMakerInfo(address _marketMaker) external view returns (MarketMakerInfo memory) {
        return marketMakers[_marketMaker];
    }
    
    /// @notice Get reward configuration
    /// @return Reward configuration struct
    function getRewardConfig() external view returns (RewardConfig memory) {
        return rewardConfig;
    }
    
    /// @notice Get total pools count
    /// @return Number of pools
    function poolLength() external view returns (uint256) {
        return pools.length;
    }
    
    /// @notice Get all market makers
    /// @return Array of market maker addresses
    function getAllMarketMakers() external view returns (address[] memory) {
        return marketMakerList;
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Update reward emission rate (governance only)
    /// @param _newEmissionRate New emission rate per second
    /// @param _newTotalEmissions New total emissions limit
    function updateEmissionRate(
        uint256 _newEmissionRate,
        uint256 _newTotalEmissions
    ) external onlyGovernance {
        require(_newTotalEmissions >= rewardConfig.emittedRewards, "INVALID_TOTAL_EMISSIONS");
        
        rewardConfig.emissionRate = _newEmissionRate;
        rewardConfig.totalEmissions = _newTotalEmissions;
        
        emit EmissionRateUpdated(_newEmissionRate, _newTotalEmissions);
    }
    
    /// @notice Update pool weights (governance only)
    /// @param _poolIds Array of pool IDs
    /// @param _allocPoints Array of new allocation points
    function updatePoolWeights(
        uint256[] calldata _poolIds,
        uint256[] calldata _allocPoints
    ) external onlyGovernance {
        require(_poolIds.length == _allocPoints.length, "ARRAY_LENGTH_MISMATCH");
        
        for (uint256 i = 0; i < _poolIds.length; i++) {
            require(_poolIds[i] < pools.length, "INVALID_POOL");
            
            _updatePool(_poolIds[i]);
            
            totalAllocPoint = totalAllocPoint - pools[_poolIds[i]].allocPoint + _allocPoints[i];
            pools[_poolIds[i]].allocPoint = _allocPoints[i];
            
            emit PoolUpdated(_poolIds[i], _allocPoints[i], pools[_poolIds[i]].baseAPY);
        }
    }
    
    /// @notice End bootstrap period early (governance only)
    function endBootstrapPeriod() external onlyGovernance {
        require(block.timestamp < rewardConfig.bootstrapEnd, "BOOTSTRAP_ALREADY_ENDED");
        
        rewardConfig.bootstrapEnd = block.timestamp;
        
        // Update all pools to remove bootstrap status
        for (uint256 i = 0; i < pools.length; i++) {
            pools[i].isBootstrap = false;
        }
        
        emit BootstrapPeriodEnded(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Emergency pause all operations
    function emergencyPause() external onlyEmergencyGuardian {
        emergencyPaused = true;
        stakingEnabled = false;
        claimingEnabled = false;
        
        emit EmergencyPaused(block.timestamp);
    }
    
    /// @notice Emergency unpause operations
    function emergencyUnpause() external onlyOwner {
        emergencyPaused = false;
        stakingEnabled = true;
        claimingEnabled = true;
        
        emit EmergencyUnpaused(block.timestamp);
    }
    
    /// @notice Emergency withdraw tokens (owner only)
    /// @param _token Token to withdraw
    /// @param _amount Amount to withdraw
    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner {
        _safeTransfer(IERC20(_token), owner, _amount);
        emit RewardTokensRecovered(_token, _amount);
    }
    
    /// @notice Set staking and claiming status
    /// @param _stakingEnabled Staking status
    /// @param _claimingEnabled Claiming status
    function setOperationsStatus(bool _stakingEnabled, bool _claimingEnabled) external onlyAuthorized {
        stakingEnabled = _stakingEnabled;
        claimingEnabled = _claimingEnabled;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Set authorized updater status
    /// @param _updater Updater address
    /// @param _status Authorization status
    function setAuthorizedUpdater(address _updater, bool _status) external onlyOwner {
        authorizedUpdaters[_updater] = _status;
    }
    
    /// @notice Set emergency guardian status
    /// @param _guardian Guardian address
    /// @param _status Guardian status
    function setEmergencyGuardian(address _guardian, bool _status) external onlyOwner {
        emergencyGuardians[_guardian] = _status;
    }
    
    /// @notice Update core contract addresses
    /// @param _treasury New treasury address
    /// @param _governance New governance address
    /// @param _oracle New oracle address
    function updateCoreContracts(
        address _treasury,
        address _governance,
        address _oracle
    ) external onlyOwner {
        if (_treasury != address(0)) treasury = ITreasury(_treasury);
        if (_governance != address(0)) governance = IGovernance(_governance);
        if (_oracle != address(0)) oracle = IOracle(_oracle);
    }
    
    /// @notice Set minimum staking interval
    /// @param _interval New interval in seconds
    function setMinStakingInterval(uint256 _interval) external onlyAuthorized {
        minStakingInterval = _interval;
    }
    
    /// @notice Fund contract with reward tokens from treasury
    /// @param _amount Amount to fund
    function fundFromTreasury(uint256 _amount) external onlyAuthorized {
        treasury.deployStabilityFunds(_amount, address(this));
        emit TreasuryFundingReceived(_amount);
    }
}
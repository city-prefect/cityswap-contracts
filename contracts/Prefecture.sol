// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";

import "./CitySwapToken.sol";
import "./TownToken.sol";

// MasterChef is the master of City Tokens. He can make CTYS and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CTYS tokens is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract Prefecture is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CTYS tokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCityPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCityPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CTYS tokens to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CTYS tokens distribution occurs.
        uint256 accCityPerShare;   // Accumulated CTYS tokens per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint256 harvestInterval;  // Harvest interval in seconds
        bool dfRate;              // Deposit fee tax rate if applicable
    }

    // The CITY TOKEN!
    CitySwapToken public city;
    // The CITY TOKEN!
    TownToken public town;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // CITY tokens created per block.
    uint256 public cityPerBlock;
    // Bonus muliplier for early CTYS makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Pool uniqueness tracker
    mapping(address => bool) private _poolTracker;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CITY mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;
    // LP tax rate which will be send to CTYS contract for automatic liquidity
    uint256 public depositFeeTaxRate = 25;

    event DevAddressUpdated(address _previousDevAddress, address _newDevAddress);
    event FeeAddressUpdated(address _previousFeeAddress, address _newFeeAddress);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);
    event DepositFeeTaxRateUpdated(address indexed user, uint256 previousAmount, uint256 newAmount);

    constructor(
        CitySwapToken _city,
        TownToken _town,
        address _devAddress,
        address _feeAddress,
        uint256 _cityPerBlock,
        uint256 _startBlock
    ) public {
        city = _city;
        town = _town;
        devAddress = _devAddress;
        feeAddress = _feeAddress;
        cityPerBlock = _cityPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // Cannot add the same LP token more than once., because rewards will be messed up if it is done
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate, bool _dfRate) public onlyOwner {
        require(_poolTracker[address(_lpToken)] == false, "add: pool already exists");
        require(_depositFeeBP <= 1000, "add: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        _poolTracker[address(_lpToken)] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accCityPerShare: 0,
            depositFeeBP: _depositFeeBP,
            harvestInterval: _harvestInterval,
            dfRate: _dfRate
        }));
    }

    // Update the given pool's CITY allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate, bool _dfRate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        poolInfo[_pid].dfRate = _dfRate;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending CTYS tokens on frontend.
    function pendingCity(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCityPerShare = pool.accCityPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 cityReward = multiplier.mul(cityPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accCityPerShare = accCityPerShare.add(cityReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accCityPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest CTYS tokens.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cityReward = multiplier.mul(cityPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        city.mint(devAddress, cityReward.div(10));
        city.mint(address(this), cityReward);
        pool.accCityPerShare = pool.accCityPerShare.add(cityReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to Prefecture for CITY allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {

        require (_pid != 0, 'deposit CITY by staking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);
        payOrLockupPendingCity(_pid);

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);

            if (address(pool.lpToken) == address(city) && city.isExcludedFromTax(msg.sender) != true) {
                uint256 transferTax = _amount.mul(city.transferTaxRate()).div(10000);
                _amount = _amount.sub(transferTax);
            }

            if (pool.depositFeeBP > 0) {
                if (pool.dfRate && depositFeeTaxRate > 0) {
                    uint256 initialDepositFee = _amount.mul(pool.depositFeeBP).div(10000);
                    uint256 lpTaxAmount = initialDepositFee.mul(depositFeeTaxRate).div(100);
                    uint256 depositFee = initialDepositFee.sub(lpTaxAmount);

                    require(initialDepositFee == depositFee + lpTaxAmount, "PREFECTURE::deposit: DF tax value invalid");
                    pool.lpToken.safeTransfer(feeAddress, depositFee);
                    pool.lpToken.safeTransfer(address(city), lpTaxAmount);

                    user.amount = user.amount.add(_amount).sub(initialDepositFee);
                } else {
                    uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                    pool.lpToken.safeTransfer(feeAddress, depositFee);
                    user.amount = user.amount.add(_amount).sub(depositFee);
                }
            } else {
                user.amount = user.amount.add(_amount);
            }
        }

        user.rewardDebt = user.amount.mul(pool.accCityPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {

        require (_pid != 0, 'withdraw CITY by leaving the pool');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingCity(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCityPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake CTYS tokens to MasterChef
    function enterStaking(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accCityPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeCityTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(city) && city.isExcludedFromTax(msg.sender) != true) {
                uint256 transferTax = _amount.mul(city.transferTaxRate()).div(10000);
                _amount = _amount.sub(transferTax);
            }
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCityPerShare).div(1e12);

        town.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw CTYS tokens from STAKING.
    function leaveStaking(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accCityPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeCityTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCityPerShare).div(1e12);

        town.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Withdraw from vault without caring about rewards. EMERGENCY ONLY.
    function vaultEmergencyWithdraw() public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        uint256 amount = user.amount;

        //Burn the town token
        town.burn(msg.sender, amount);

        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending CTYS tokens.
    function payOrLockupPendingCity(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accCityPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // send rewards
                safeCityTransfer(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe CTYS transfer function, just in case if rounding error causes pool to not have enough CTYS tokens.
    function safeCityTransfer(address _to, uint256 _amount) internal {
        uint256 cityBalance = city.balanceOf(address(this));
        if (_amount > cityBalance) {
            city.transfer(_to, cityBalance);
        } else {
            city.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) external {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN, Hans forget the flammenwerfer, bring the gustav");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        emit DevAddressUpdated(devAddress, _devAddress);
        devAddress = _devAddress;
    }

    // Update dev address by the previous dev.
    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN, Hans get the flammenwerfer");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        emit FeeAddressUpdated(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _cityPerBlock) external onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, cityPerBlock, _cityPerBlock);
        cityPerBlock = _cityPerBlock;
    }

    // Update deposit fee tax rate
    function updateDepositFeeTaxRate(uint256 _depositFeeTaxRate) external onlyOwner {
        emit DepositFeeTaxRateUpdated(msg.sender, depositFeeTaxRate, _depositFeeTaxRate);
        depositFeeTaxRate = _depositFeeTaxRate;
    }

    // Get CTYS transfer tax rate
    function cityTransferTaxRate() external view returns (uint16) {
        return city.transferTaxRate();
    }

    // Get CTYS burn rate
    function cityBurnRate() external view returns (uint16) {
        return city.burnRate();
    }
}

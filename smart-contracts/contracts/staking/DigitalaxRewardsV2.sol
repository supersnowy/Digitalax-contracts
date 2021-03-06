// SPDX-License-Identifier: GPLv2

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../DigitalaxAccessControls.sol";
import "./interfaces/IERC20.sol";
//import "../oracle/IDigitalaxMonaOracle.sol";
import "../EIP2771/BaseRelayRecipient.sol";

import "hardhat/console.sol";

/**
 * @title Digitalax Rewards
 * @dev Calculates the rewards for staking on the Digitalax platform
 * @author DIGITALAX CORE TEAM
 * @author Based on original staking contract by Adrian Guerrera (deepyr)
 */

interface DigitalaxStaking {
    function stakedValueTotalForPool() external view returns (uint256);
    function earlyStakedValueTotalForPool() external view returns (uint256);
    function monaToken() external view returns (address);
}

interface MONA is IERC20 {
    function mint(address tokenOwner, uint tokens) external returns (bool);
}

contract DigitalaxRewardsV2 is BaseRelayRecipient {
    using SafeMath for uint256;

    /* ========== Variables ========== */

    MONA public monaToken;
    bool initialised;

    DigitalaxAccessControls public accessControls;
    DigitalaxStaking public monaStaking;

    mapping(address => uint256) public rewardTokensIndex;
    address[] public rewardTokens;

    uint256 public MAX_REWARD_TOKENS;
    uint256 constant pointMultiplier = 10e18;
    uint256 constant SECONDS_PER_DAY = 24 * 60 * 60;
    uint256 constant SECONDS_PER_WEEK = 7 * 24 * 60 * 60;

    mapping (uint256 => uint256) public weeklyMonaRevenueSharingPerSecond; // Mona revenue sharing
    mapping (uint256 => uint256) public bonusWeeklyMonaRevenueSharingPerSecond; // Mona revenue sharing
    mapping (address => mapping(uint256 => uint256)) public weeklyTokenRevenueSharingPerSecond; // All token  revenue sharing

    // Staking pool rewards
    uint256 public startTime;
    uint256 public normalMonaRewardsPaid;
    uint256 public monaRewardsPaidTotal;
    uint256 public bonusMonaRewardsPaidTotal;
    mapping(address => uint256) public tokenRewardsPaidTotal;

    uint256 public lastRewardsTime;
    mapping(address => uint256) public tokenRewardsPaid;


    /* ========== Events ========== */
    event UpdateAccessControls(
        address indexed accessControls
    );
    event RewardAdded(address indexed addr, uint256 reward);
    event RewardDistributed(address indexed addr, uint256 reward);
    event ReclaimedERC20(address indexed token, uint256 amount);



    // Events
    event AddRewardTokens(
        address[] rewardTokens
    );

    event RemoveRewardTokens(
        address[] rewardTokens
    );

    event DepositRevenueSharing(
        uint256 week,
        uint256 weeklyMonaRevenueSharingPerSecond,
        uint256 bonusWeeklyMonaRevenueSharingPerSecond,
        address[] rewardTokens,
        uint256[] rewardAmounts);

    event WithdrawRevenueSharing(
        uint256 week,
        uint256 amount,
        uint256 bonusAmount,
        address[] rewardTokens,
        uint256[] rewardTokenAmounts
    );

    /* ========== Admin Functions ========== */
    function initialize(
        MONA _monaToken,
        DigitalaxAccessControls _accessControls,
        DigitalaxStaking _monaStaking,
        address _trustedForwarder,
        uint256 _startTime,
        uint256 _monaRewardsPaidTotal,
        uint256 _bonusMonaRewardsPaidTotal
    )
        public
    {
        require(!initialised);
        require(
            address(_monaToken) != address(0),
            "DigitalaxRewardsV2: Invalid Mona Address"
        );
        require(
            address(_accessControls) != address(0),
            "DigitalaxRewardsV2: Invalid Access Controls"
        );
        require(
            address(_monaStaking) != address(0),
            "DigitalaxRewardsV2: Invalid Mona Staking"
        );
        monaToken = _monaToken;
        accessControls = _accessControls;
        monaStaking = _monaStaking;
        startTime = _startTime;
        monaRewardsPaidTotal = _monaRewardsPaidTotal;
        bonusMonaRewardsPaidTotal = _bonusMonaRewardsPaidTotal;
        trustedForwarder = _trustedForwarder;
        MAX_REWARD_TOKENS = 200;
        initialised = true;
    }
    receive() external payable {
    }


    function setTrustedForwarder(address _trustedForwarder) external  {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.setTrustedForwarder: Sender must be admin"
            );
            trustedForwarder = _trustedForwarder;
    }

    // This is to support Native meta transactions
    // never use msg.sender directly, use _msgSender() instead
    function _msgSender()
    internal
    view
    returns (address payable sender)
    {
        return BaseRelayRecipient.msgSender();
    }
    /**
       * Override this function.
       * This version is to keep track of BaseRelayRecipient you are using
       * in your contract.
       */
    function versionRecipient() external view override returns (string memory) {
        return "1";
    }


/*
 * @notice Set the start time
 * @dev Setter functions for contract config
*/
    function setStartTime(
        uint256 _startTime
    )
        external
    {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.setStartTime: Sender must be admin"
        );
        startTime = _startTime;
    }


    /**
     @notice Method for updating the access controls contract used by the NFT
     @dev Only admin
     @param _accessControls Address of the new access controls contract (Cannot be zero address)
     */
    function updateAccessControls(DigitalaxAccessControls _accessControls) external {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.updateAccessControls: Sender must be admin"
        );
        require(address(_accessControls) != address(0), "DigitalaxRewardsV2.updateAccessControls: Zero Address");
        accessControls = _accessControls;
        emit UpdateAccessControls(address(_accessControls));
    }

    /**
     @notice Method for updating the address of the mona staking contract
     @dev Only admin
     @param _addr Address of the mona staking contract
    */
    function setMonaStaking(address _addr)
        external
        {
            require(
                accessControls.hasAdminRole(_msgSender()),
                "DigitalaxRewardsV2.setMonaStaking: Sender must be admin"
            );
            monaStaking = DigitalaxStaking(_addr);
    }

    /*
     * @notice Deposit revenue sharing rewards to be distributed during a certain week
     * @dev this number is the total rewards that week with 18 decimals
     */
    function depositRevenueSharingRewards(
        uint256 _week,
        uint256 _amount,
        uint256 _bonusAmount,
        address[] memory _rewardTokens,
        uint256[] memory _rewardAmounts
    )
        external
    {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.setRewards: Sender must be admin"
        );

        require(
            _week >= getCurrentWeek(),
            "DigitalaxRewardsV2.depositRevenueSharingRewards: The rewards generated should be set for the future weeks"
        );

        require(IERC20(monaToken).allowance(_msgSender(), address(this)) >= _amount.add(_bonusAmount), "DigitalaxRewardsV2.depositRevenueSharingRewards: Failed to supply ERC20 Allowance");

        // Deposit this amount of MONA here
        require(IERC20(monaToken).transferFrom(
            address(_msgSender()),
            address(this),
            _amount.add(_bonusAmount)
        ));


        uint256 monaAmount = _amount.mul(pointMultiplier)
                                   .div(SECONDS_PER_WEEK)
                                   .div(pointMultiplier);

        uint256 bonusMonaAmount = _bonusAmount.mul(pointMultiplier)
                                   .div(SECONDS_PER_WEEK)
                                   .div(pointMultiplier);


        // Increase the revenue sharing per second for the week for Mona
        weeklyMonaRevenueSharingPerSecond[_week] = weeklyMonaRevenueSharingPerSecond[_week].add(monaAmount);
        bonusWeeklyMonaRevenueSharingPerSecond[_week] = bonusWeeklyMonaRevenueSharingPerSecond[_week].add(bonusMonaAmount);

        for (uint i = 0; i < _rewardTokens.length; i++) {
            require(_rewardTokens[i] != address(0), "This param is not for 0 address");
            require(IERC20(_rewardTokens[i]).allowance(_msgSender(), address(this)) >= _rewardAmounts[i], "DepositRevenueSharingRewards: Failed to supply ERC20 Allowance");

            // Deposit this amount of MONA here
            require(IERC20(_rewardTokens[i]).transferFrom(
                address(_msgSender()),
                address(this),
                _rewardAmounts[i]
            ));

            uint256 rewardAmount = _rewardAmounts[i].mul(pointMultiplier)
                .div(SECONDS_PER_WEEK)
                .div(pointMultiplier);

            weeklyTokenRevenueSharingPerSecond[_rewardTokens[i]][_week] = weeklyTokenRevenueSharingPerSecond[_rewardTokens[i]][_week].add(rewardAmount);
         }

        emit DepositRevenueSharing(_week, weeklyMonaRevenueSharingPerSecond[_week], bonusWeeklyMonaRevenueSharingPerSecond[_week], _rewardTokens, _rewardAmounts);
    }

    function withdrawMonaRewards(
            uint256 _week,
            uint256 _amount,
            uint256 _bonusAmount,
            address[] memory _rewardTokens,
            uint256[] memory _rewardAmounts) external {

        require(
        accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.withdrawMonaRewards: Sender must be admin"
        );

//        require(
//        _week >= getCurrentWeek(),
//            "DigitalaxRewardsV2.withdrawMonaRewards: The rewards generated should be set for the future weeks"
//        );

        uint256 monaAmount = _amount.mul(pointMultiplier)
            .div(SECONDS_PER_WEEK)
            .div(pointMultiplier);

        uint256 bonusMonaAmount = _bonusAmount.mul(pointMultiplier)
            .div(SECONDS_PER_WEEK)
            .div(pointMultiplier);


        require(monaAmount <= weeklyMonaRevenueSharingPerSecond[_week], "DigitalaxRewardsV2.withdrawMonaRewards: Cannot withdraw back more then week amount");

        // Withdraw this amount of MONA
        IERC20(monaToken).transferFrom(
            address(this),
            _msgSender(),
            _amount.add(_bonusAmount)
        );

        // Reduce the revenue sharing per second for the week for Mona
        weeklyMonaRevenueSharingPerSecond[_week] = weeklyMonaRevenueSharingPerSecond[_week].sub(monaAmount);
        bonusWeeklyMonaRevenueSharingPerSecond[_week] = bonusWeeklyMonaRevenueSharingPerSecond[_week].sub(bonusMonaAmount);

        for (uint i = 0; i < _rewardTokens.length; i++) {
            require(_rewardTokens[i] != address(0) && _rewardTokens[i] != address(monaToken), "This param is not for MONA or 0 address");

            uint256 rewardAmount = _rewardAmounts[i].mul(pointMultiplier)
                .div(SECONDS_PER_WEEK)
                .div(pointMultiplier);

            require(rewardAmount <= weeklyMonaRevenueSharingPerSecond[_week], "DigitalaxRewardsV2.withdrawMonaRewards: Cannot withdraw back more then week amount");


            // Deposit this amount of MONA here
            require(IERC20(_rewardTokens[i]).transferFrom(
                address(this),
                address(_msgSender()),
                _rewardAmounts[i]
            ));

            weeklyTokenRevenueSharingPerSecond[_rewardTokens[i]][_week] = weeklyTokenRevenueSharingPerSecond[_rewardTokens[i]][_week].sub(rewardAmount);
        }
        emit WithdrawRevenueSharing(_week, _amount, _bonusAmount, _rewardTokens, _rewardAmounts);
}


/* From BokkyPooBah's DateTime Library v1.01
 * https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary
 */
    function diffDays(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _days) {
        require(fromTimestamp <= toTimestamp);
        _days = (toTimestamp - fromTimestamp) / SECONDS_PER_DAY;
    }


    /* ========== Mutative Functions ========== */

    /* @notice Calculate and update rewards
     * @dev
     */
    function updateRewards()
        external
        returns(bool)
    {
        if (_getNow() <= lastRewardsTime) {
            return false;
        }

        /// @dev check that the staking pools have contributions, and rewards have started
        if (_getNow() <= startTime) {
            lastRewardsTime = _getNow();
            return false;
        }

        /// @dev This sends rewards (Mona from revenue sharing)
        _updateMonaRewards();

        /// @dev This sends the bonus rewards (Mona from revenue sharing)
        _updateBonusMonaRewards();

        /// @dev This updates the extra token rewards (Any token from revenue sharing)
        _updateTokenRewards();

        /// @dev update accumulated reward
        lastRewardsTime = _getNow();
        return true;
    }


    /*
     * @dev Setter functions for contract config custom last rewards time for a pool
     */
    function setLastRewardsTime(
    uint256 _lastRewardsTime) external
    {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.setLastRewardsTime: Sender must be admin"
        );
        lastRewardsTime = _lastRewardsTime;

    }

    /*
     * @dev Setter functions for contract config custom last rewards time for a pool
     */
    function setMaxRewardsTokens(
    uint256 _maxRewardsTokensCount) external
    {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.setMaxRewardsTokens: Sender must be admin"
        );
        MAX_REWARD_TOKENS = _maxRewardsTokensCount;

    }

    function addRewardTokens(address[] memory _rewardTokens) public {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "AddRewardTokens: Sender must be admin"
        );
        require((_rewardTokens.length) > 0, "AddRewardTokens: Empty array not supported");
        require(MAX_REWARD_TOKENS >= _rewardTokens.length, "AddRewardTokens: Already reached max erc20 supported");
        for (uint i = 0; i < _rewardTokens.length; i++) {
            if(!checkInRewardTokens(_rewardTokens[i])) {
                uint256 index = rewardTokens.length;
                rewardTokens.push(_rewardTokens[i]);
                rewardTokensIndex[_rewardTokens[i]] = index;
            }
        }
        emit AddRewardTokens(_rewardTokens);
    }

    function removeRewardTokens(address[] memory _rewardTokens) public {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "RemoveRewardTokens: Sender must be admin"
        );

        require((rewardTokens.length) > 0, "RemoveRewardTokens: No reward tokens instantiated");
        require((_rewardTokens.length) > 0, "RemoveRewardTokens: Empty array not supported");

        for (uint i = 0; i < _rewardTokens.length; i++) {
            if(checkInRewardTokens(_rewardTokens[i])) {
                uint256 rowToDelete = rewardTokensIndex[_rewardTokens[i]];
                address keyToMove = rewardTokens[rewardTokens.length-1];
                rewardTokens[rowToDelete] = keyToMove;
                rewardTokensIndex[keyToMove] = rowToDelete;
                rewardTokens.pop();
                delete(rewardTokensIndex[_rewardTokens[i]]);
            }
        }

        emit RemoveRewardTokens(_rewardTokens);
    }

    function checkInRewardTokens(address _rewardToken) public view returns (bool isAddress) {
        if(rewardTokens.length == 0) return false;
        return (rewardTokens[rewardTokensIndex[_rewardToken]] == _rewardToken);
    }

    function getExtraRewardTokens() external view returns (address[] memory returnRewardTokens){
        return getRewardTokens();
    }

    function getRewardTokens() internal view returns (address[] memory returnRewardTokens){
        address[] memory a = new address[](rewardTokens.length);
        for (uint i=0; i< rewardTokens.length; i++) {
            a[i] = rewardTokens[i];
        }
        return a;
    }

    /* ========== View Functions ========== */

    /*
     * @notice Gets the total rewards outstanding from last reward time
     */
    function totalNewMonaRewards() external view returns (uint256) {
        uint256 lRewards = MonaRevenueRewards(lastRewardsTime, _getNow());
        return lRewards;
    }

    /*
     * @notice Gets the total rewards outstanding from last reward time
     */
    function totalNewBonusMonaRewards() external view returns (uint256) {
        uint256 lRewards = BonusMonaRevenueRewards(lastRewardsTime, _getNow());
        return lRewards;
    }

    /*
     * @notice Gets the total rewards outstanding from last reward time
     */
    function totalNewRewardsWithToken(address _rewardToken) external view returns (uint256) {
        uint256 lRewards = TokenRevenueRewards(_rewardToken, lastRewardsTime, _getNow());
        return lRewards;
    }

    /* @notice Return mona revenue rewards over the given _from to _to timestamp.
     * @dev A fraction of the start, multiples of the middle weeks, fraction of the end
     */
    function MonaRevenueRewards(uint256 _from, uint256 _to) public view returns (uint256 rewards) {
        if (_to <= startTime) {
            return 0;
        }
        if (_from < startTime) {
            _from = startTime;
        }
        uint256 fromWeek = diffDays(startTime, _from) / 7;
        uint256 toWeek = diffDays(startTime, _to) / 7;

        if (fromWeek == toWeek) {
            return _rewardsFromPoints(weeklyMonaRevenueSharingPerSecond[fromWeek],
                                    _to.sub(_from));
        }
        /// @dev First count remainder of first week
        uint256 initialRemander = startTime.add((fromWeek+1).mul(SECONDS_PER_WEEK)).sub(_from);
        rewards = _rewardsFromPoints(weeklyMonaRevenueSharingPerSecond[fromWeek],
                                    initialRemander);

        /// @dev add multiples of the week
        for (uint256 i = fromWeek+1; i < toWeek; i++) {
            rewards = rewards.add(_rewardsFromPoints(weeklyMonaRevenueSharingPerSecond[i],
                                    SECONDS_PER_WEEK));
        }
        /// @dev Adds any remaining time in the most recent week till _to
        uint256 finalRemander = _to.sub(toWeek.mul(SECONDS_PER_WEEK).add(startTime));
        rewards = rewards.add(_rewardsFromPoints(weeklyMonaRevenueSharingPerSecond[toWeek],
                                    finalRemander));
        return rewards;
    }

    /* @notice Return bonus mona revenue rewards over the given _from to _to timestamp.
     * @dev A fraction of the start, multiples of the middle weeks, fraction of the end
     */
    function BonusMonaRevenueRewards(uint256 _from, uint256 _to) public view returns (uint256 rewards) {
        if (_to <= startTime) {
            return 0;
        }
        if (_from < startTime) {
            _from = startTime;
        }
        uint256 fromWeek = diffDays(startTime, _from) / 7;
        uint256 toWeek = diffDays(startTime, _to) / 7;

        if (fromWeek == toWeek) {
            return _rewardsFromPoints(bonusWeeklyMonaRevenueSharingPerSecond[fromWeek],
                                    _to.sub(_from));
        }
        /// @dev First count remainder of first week
        uint256 initialRemander = startTime.add((fromWeek+1).mul(SECONDS_PER_WEEK)).sub(_from);
        rewards = _rewardsFromPoints(bonusWeeklyMonaRevenueSharingPerSecond[fromWeek],
                                    initialRemander);

        /// @dev add multiples of the week
        for (uint256 i = fromWeek+1; i < toWeek; i++) {
            rewards = rewards.add(_rewardsFromPoints(bonusWeeklyMonaRevenueSharingPerSecond[i],
                                    SECONDS_PER_WEEK));
        }
        /// @dev Adds any remaining time in the most recent week till _to
        uint256 finalRemander = _to.sub(toWeek.mul(SECONDS_PER_WEEK).add(startTime));
        rewards = rewards.add(_rewardsFromPoints(bonusWeeklyMonaRevenueSharingPerSecond[toWeek],
                                    finalRemander));
        return rewards;
    }

    /* @notice Return bonus mona revenue rewards over the given _from to _to timestamp.
     * @dev A fraction of the start, multiples of the middle weeks, fraction of the end
     */
    function TokenRevenueRewards(address _rewardToken, uint256 _from, uint256 _to) public view returns (uint256 rewards) {
        if (_to <= startTime) {
            return 0;
        }
        if (_from < startTime) {
            _from = startTime;
        }
        uint256 fromWeek = diffDays(startTime, _from) / 7;
        uint256 toWeek = diffDays(startTime, _to) / 7;

        if (fromWeek == toWeek) {
            return _rewardsFromPoints(weeklyTokenRevenueSharingPerSecond[_rewardToken][fromWeek],
                                    _to.sub(_from));
        }
        /// @dev First count remainder of first week
        uint256 initialRemander = startTime.add((fromWeek+1).mul(SECONDS_PER_WEEK)).sub(_from);
        rewards = _rewardsFromPoints(weeklyTokenRevenueSharingPerSecond[_rewardToken][fromWeek],
                                    initialRemander);

        /// @dev add multiples of the week
        for (uint256 i = fromWeek+1; i < toWeek; i++) {
            rewards = rewards.add(_rewardsFromPoints(weeklyTokenRevenueSharingPerSecond[_rewardToken][i],
                                    SECONDS_PER_WEEK));
        }
        /// @dev Adds any remaining time in the most recent week till _to
        uint256 finalRemander = _to.sub(toWeek.mul(SECONDS_PER_WEEK).add(startTime));
        rewards = rewards.add(_rewardsFromPoints(weeklyTokenRevenueSharingPerSecond[_rewardToken][toWeek],
                                    finalRemander));
        return rewards;
    }

    /* ========== Internal Functions ========== */


    function _updateTokenRewards()
        internal
        returns(uint256 rewards)
    {
        address[] memory _rewardsTokens = getRewardTokens();
        for (uint i = 0; i < _rewardsTokens.length; i++)
        {
            rewards = TokenRevenueRewards(_rewardsTokens[i], lastRewardsTime, _getNow());
            if ( rewards > 0 ) {
            tokenRewardsPaidTotal[_rewardsTokens[i]] = tokenRewardsPaidTotal[_rewardsTokens[i]].add(rewards);

                // Send this amount of MONA to the staking contract
                IERC20(_rewardsTokens[i]).transfer(
                    address(monaStaking),
                    rewards
                );
            }
        }
    }

    function _updateMonaRewards()
        internal
        returns(uint256 rewards)
    {
        rewards = MonaRevenueRewards(lastRewardsTime, _getNow());
        if ( rewards > 0 ) {
            monaRewardsPaidTotal = monaRewardsPaidTotal.add(rewards);
            normalMonaRewardsPaid = normalMonaRewardsPaid.add(rewards);

            // Send this amount of MONA to the staking contract
            IERC20(monaToken).transfer(
                address(monaStaking),
                rewards
            );
        }
    }

    function _updateBonusMonaRewards()
        internal
        returns(uint256 rewards)
    {
        rewards = BonusMonaRevenueRewards(lastRewardsTime, _getNow());
        if ( rewards > 0 ) {
            monaRewardsPaidTotal = monaRewardsPaidTotal.add(rewards);
            bonusMonaRewardsPaidTotal = bonusMonaRewardsPaidTotal.add(rewards);

            // Send this amount of MONA to the staking contract
            IERC20(monaToken).transfer(
                address(monaStaking),
                rewards
            );
        }
    }

    function getLastRewardsTime() external view returns(uint256 lastRewardsT){
        return lastRewardsTime;
    }

    function _rewardsFromPoints(
        uint256 rate,
        uint256 duration
    )
        internal
        pure
        returns(uint256)
    {
        return rate.mul(duration);
    }


    /* ========== Reclaim ERC20 ========== */

    /*
     * @notice allows for the recovery of incorrect ERC20 tokens sent to contract
     */
    function reclaimERC20(
        address _tokenAddress,
        uint256 _tokenAmount
    )
        external
    {
        // Cannot recover the staking token or the rewards token
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.reclaimERC20: Sender must be admin"
        );
//        require(
//            tokenAddress != address(monaToken),
//            "Cannot withdraw the rewards token"
//        );
        IERC20(_tokenAddress).transfer(_msgSender(), _tokenAmount);
        emit ReclaimedERC20(_tokenAddress, _tokenAmount);
    }

    /**
    * @notice EMERGENCY Recovers ETH, drains amount of eth sitting on the smart contract
    * @dev Only access controls admin can access
    */
    function reclaimETH(uint256 _amount) external {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxRewardsV2.reclaimETH: Sender must be admin"
        );
        _msgSender().transfer(_amount);
    }


    /* ========== Getters ========== */

    function getCurrentWeek()
        public
        view
        returns(uint256)
    {
        return diffDays(startTime, _getNow()) / 7;
    }

    function getMonaStakedValueTotal()
        public
        view
        returns(uint256)
    {
        return monaStaking.stakedValueTotalForPool();
    }

    function getMonaDailyAPY(bool isEarlyStaker)
        external
        view
        returns (uint256)
    {
        uint256 stakedValue = monaStaking.stakedValueTotalForPool();

        uint256 yearlyReturnPerMona = 0;

        if ( stakedValue != 0) {
            uint256 rewards = MonaRevenueRewards( _getNow() - 60, _getNow());

            /// @dev minutes per year x 100 = 52560000
            yearlyReturnPerMona = rewards.mul(52560000).mul(1e18).div(stakedValue);
        }

        uint256 yearlyEarlyReturnPerMona = 0;

        if(isEarlyStaker){
            uint256 earlystakedValue = monaStaking.earlyStakedValueTotalForPool();
            if ( earlystakedValue != 0) {
                uint256 bonusRewards = BonusMonaRevenueRewards(_getNow() - 60, _getNow());

                /// @dev minutes per year x 100 = 52560000
                yearlyEarlyReturnPerMona = bonusRewards.mul(52560000).mul(1e18).div(earlystakedValue);
            }
        }
      return yearlyReturnPerMona.add(yearlyEarlyReturnPerMona);
    }

    // Get the amount of yearly return of rewards token per 1 MONA
   function getTokenRewardDailyAPY(address _rewardToken)
        external
        view
        returns (uint256)
    {
        uint256 stakedValue = monaStaking.stakedValueTotalForPool();

        uint256 yearlyReturnPerMona = 0;

        if ( stakedValue != 0) {
            uint256 rewards = TokenRevenueRewards(_rewardToken, _getNow() - 60, _getNow());

            /// @dev minutes per year x 100 = 52560000
            yearlyReturnPerMona = rewards.mul(52560000).mul(1e18).div(stakedValue);
        }
      return yearlyReturnPerMona;
    }


    function _getNow() internal virtual view returns (uint256) {
        return block.timestamp;
    }
}

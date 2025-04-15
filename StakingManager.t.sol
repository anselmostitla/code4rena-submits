// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";
import "../src/interfaces/IStakingManager.sol";

contract StakingManagerTest is BaseTest {
    // Declare events directly
    event StakeReceived(address indexed staking, address indexed staker, uint256 amount);
    event WithdrawalQueued(
        address indexed staking,
        address indexed user,
        uint256 indexed withdrawalId,
        uint256 kHYPEAmount,
        uint256 hypeAmount,
        uint256 feeAmount
    );
    event WithdrawalConfirmed(address indexed user, uint256 indexed withdrawalId, uint256 amount);
    event StakingLimitUpdated(uint256 newStakingLimit);
    event MinStakeAmountUpdated(uint256 newMinStakeAmount);
    event MaxStakeAmountUpdated(uint256 newMaxStakeAmount);
    event ValidatorWithdrawal(address indexed staking, address indexed validator, uint256 amount);
    event Delegate(address indexed staking, address indexed validator, uint256 amount);
    event L1DelegationQueued(
        address indexed staking,
        address indexed validator,
        uint256 amount,
        IStakingManager.OperationType operationType
    );

    address public validator;
    address public validator1;
    address public validator2;

    function setUp() public override {
        super.setUp();

        // Setup validator addresses
        validator = makeAddr("validator");
        validator1 = makeAddr("validator1");
        validator2 = makeAddr("validator2");

        // Grant roles
        vm.startPrank(admin);
        stakingManager.grantRole(stakingManager.OPERATOR_ROLE(), operator);
        stakingManager.grantRole(stakingManager.MANAGER_ROLE(), manager);
        vm.stopPrank();
    }

    function test_InitialState() public view {
        assertTrue(stakingManager.hasRole(stakingManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(stakingManager.hasRole(stakingManager.OPERATOR_ROLE(), operator));
        assertTrue(stakingManager.hasRole(stakingManager.MANAGER_ROLE(), manager));

        assertEq(address(stakingManager.pauserRegistry()), address(pauserRegistry));
        assertEq(address(stakingManager.validatorManager()), address(validatorManager));
        assertEq(address(stakingManager.kHYPE()), address(kHYPE));

        assertEq(stakingManager.minStakeAmount(), minStake);
        assertEq(stakingManager.maxStakeAmount(), maxStake);
        assertEq(stakingManager.stakingLimit(), stakingLimit);
        assertEq(stakingManager.totalStaked(), 0);
        assertEq(stakingManager.totalClaimed(), 0);
        assertEq(stakingManager.totalQueuedWithdrawals(), 0);
    }

    function test_Stake_Success() public {
        uint256 stakeAmount = 1 ether;

        // Set up delegation first
        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager), validator);
        vm.stopPrank();

        vm.deal(user, stakeAmount);
        vm.prank(user);

        // Check for the correct event
        vm.expectEmit(true, true, false, true);
        emit StakeReceived(address(stakingManager), user, stakeAmount);

        stakingManager.stake{value: stakeAmount}();

        assertEq(stakingManager.totalStaked(), stakeAmount);
        assertEq(kHYPE.balanceOf(user), stakeAmount);

        // q where is the ethereum, one part it is suppose to be in StakingManager (is our buffer) and the other part it is supposed to be in L1
        /*
            We need to make a lot of staking to pass the limitStaking to test that the remainder goes to L1
        */
    }

    function test_QueueWithdrawal_Success() public {
        uint256 amount = 1 ether;

        // Setup validator and delegation
        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager), validator);
        vm.stopPrank();

        // Setup initial stake
        vm.deal(user, amount);
        vm.prank(user);
        stakingManager.stake{value: amount}();

        // Approve StakingManager to spend kHYPE tokens
        vm.prank(user);
        kHYPE.approve(address(stakingManager), amount);

        // Calculate fee (10 basis points = 0.1%)
        uint256 feeRate = stakingManager.unstakeFeeRate();
        uint256 feeAmount = (amount * feeRate) / stakingManager.BASIS_POINTS();
        uint256 postFeeAmount = amount - feeAmount;

        // Queue withdrawal
        vm.prank(user);
        stakingManager.queueWithdrawal(amount);

        // Verify withdrawal request
        StakingManager.WithdrawalRequest memory request = stakingManager.withdrawalRequests(user, 0);
        assertEq(request.hypeAmount, postFeeAmount, "Incorrect HYPE amount");
        assertEq(request.kHYPEAmount, amount - feeAmount, "Incorrect kHYPE amount");
        assertEq(request.kHYPEFee, feeAmount, "Incorrect fee amount");
    }

    function test_QueueWithdrawal_TreasuryBypassesFee() public {
        uint256 amount = 1 ether;

        // Setup validator and delegation
        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager), validator);
        vm.stopPrank();

        // Setup initial stake for treasury
        address treasury = stakingManager.treasury();
        vm.deal(treasury, amount);
        vm.prank(treasury);
        stakingManager.stake{value: amount}();

        // Approve StakingManager to spend kHYPE tokens
        vm.prank(treasury);
        kHYPE.approve(address(stakingManager), amount);

        // Queue withdrawal from treasury
        vm.prank(treasury);
        stakingManager.queueWithdrawal(amount);

        // Verify withdrawal request has no fee
        StakingManager.WithdrawalRequest memory request = stakingManager.withdrawalRequests(treasury, 0);
        assertEq(request.hypeAmount, amount, "Treasury should not pay fee");
        assertEq(request.kHYPEAmount, amount, "Treasury should not pay fee");
        assertEq(request.kHYPEFee, 0, "Treasury fee should be zero");
    }

    /*
    What happend if the target is set as one third of the limitStaking. 
    For example, 
    user1 deposits 1 ether
    user2 deposits 1 ether
    user3 deposits 1 ether
    user4 deposits 6 ether

    Then suddendly user4 request a withdrawal of 7, since target is 3 as the limitStaking is 10. user4 will only be able to requestWithdrawal of 3 and not of 7, how can user4 will be able to request for the rest of the staked eth.

    will this be a denail of service.
    what would happend i now user 3 wants to withdraw his 1 ether, he wont be able unless there is a transfer from L1 to Staking Manager Contract

    */

    function test_ConfirmWithdrawal() public {
        // Setup initial stake and withdrawal
        uint256 stakeAmount = 1 ether;
        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager), validator);
        vm.stopPrank();

        vm.deal(user, stakeAmount);
        vm.prank(user);
        stakingManager.stake{value: stakeAmount}();

        // Approve and queue withdrawal
        vm.startPrank(user);
        kHYPE.approve(address(stakingManager), stakeAmount);
        // Store the withdrawalId (should be 0 for first withdrawal)
        uint256 withdrawalId = 0;
        stakingManager.queueWithdrawal(stakeAmount);
        vm.stopPrank();

        // Add ETH to the StakingManager contract to process the withdrawal
        vm.deal(address(stakingManager), stakeAmount);

        // Set withdrawal delay to 0 to allow immediate confirmation
        vm.prank(manager);
        stakingManager.setWithdrawalDelay(0);

        // Get the actual withdrawal request details to use in our event expectation
        StakingManager.WithdrawalRequest memory request = stakingManager.withdrawalRequests(user, withdrawalId);
        uint256 hypeAmount = request.hypeAmount;

        // Confirm withdrawal - use the actual hypeAmount from the request
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit WithdrawalConfirmed(user, withdrawalId, hypeAmount);
        stakingManager.confirmWithdrawal(withdrawalId);

        // Calculate the expected fee (0.1% of stakeAmount)
        uint256 feeRate = stakingManager.unstakeFeeRate();
        uint256 expectedFee = (stakeAmount * feeRate) / stakingManager.BASIS_POINTS();
        uint256 expectedClaimedAmount = stakeAmount - expectedFee;

        assertEq(stakingManager.totalQueuedWithdrawals(), 0);
        assertEq(stakingManager.totalClaimed(), expectedClaimedAmount, "Total claimed should account for fee");
    }

    function test_SetStakingLimit() public {
        uint256 newLimit = 1000 ether;
        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit StakingLimitUpdated(newLimit);
        stakingManager.setStakingLimit(newLimit);

        assertEq(stakingManager.stakingLimit(), newLimit);
    }

    function test_SetMinStakeAmount() public {
        uint256 newMin = 0.1 ether;

        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit MinStakeAmountUpdated(newMin);
        stakingManager.setMinStakeAmount(newMin);

        assertEq(stakingManager.minStakeAmount(), newMin);
    }

    function test_SetMaxStakeAmount() public {
        uint256 newMax = 10 ether;

        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit MaxStakeAmountUpdated(newMax);
        stakingManager.setMaxStakeAmount(newMax);

        assertEq(stakingManager.maxStakeAmount(), newMax);
    }

    function test_SetTargetBuffer() public {
        uint256 newTarget = 5 ether;

        vm.prank(manager);
        stakingManager.setTargetBuffer(newTarget);

        assertEq(stakingManager.targetBuffer(), newTarget);
    }

    function test_RevertWhenPaused() public {
        // Pause contract
        vm.prank(pauser);
        pauserRegistry.pauseContract(address(stakingManager));

        // Try to stake
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert("Contract is paused");
        stakingManager.stake{value: 1 ether}();
    }

    function test_ProcessValidatorWithdrawals_Success() public {
        address[] memory validators = new address[](2);
        validators[0] = validator1;
        validators[1] = validator2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 20 ether;

        // Expect withdrawal events with correct parameters
        vm.expectEmit(true, true, false, true);
        emit ValidatorWithdrawal(address(stakingManager), validator1, 30 ether);
        vm.expectEmit(true, true, false, true);
        emit ValidatorWithdrawal(address(stakingManager), validator2, 20 ether);

        vm.startPrank(address(validatorManager));
        stakingManager.processValidatorWithdrawals(validators, amounts);
        vm.stopPrank();
    }

    function test_ProcessValidatorRedelegation_Success() public {
        // Setup validator first
        vm.startPrank(manager);
        validatorManager.activateValidator(validator1);
        validatorManager.setDelegation(address(stakingManager), validator1);
        vm.stopPrank();

        // Setup balance
        vm.deal(address(stakingManager), 100 ether);

        // Only ValidatorManager can call this
        vm.prank(address(validatorManager));

        // Expect both events in the correct order
        vm.expectEmit(true, true, false, true);
        emit L1DelegationQueued(
            address(stakingManager),
            validator1,
            50 ether / 1e10,
            IStakingManager.OperationType.RebalanceDeposit
        );

        vm.expectEmit(true, true, false, false);
        emit Delegate(address(stakingManager), validator1, 50 ether / 1e10);

        stakingManager.processValidatorRedelegation(50 ether);
    }

    function test_ProcessValidatorWithdrawals_RevertUnauthorized() public {
        address[] memory validators = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        vm.prank(user);
        vm.expectRevert("Only ValidatorManager");
        stakingManager.processValidatorWithdrawals(validators, amounts);
    }

    function test_ProcessValidatorRedelegation_RevertUnauthorized() public {
        vm.prank(user);
        vm.expectRevert("Only ValidatorManager");
        stakingManager.processValidatorRedelegation(1 ether);
    }

    function testBigUserCannotWithdraw() public {
        
        // setStakingLimit
        uint256 limit = 10;
        uint256 newLimit = limit * 1 ether;
        vm.prank(manager);
        stakingManager.setStakingLimit(newLimit);

        // Set up delegation first
        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager), validator);
        vm.stopPrank();

        // We need to put here various users to deposit
        uint numUsers = 4;

        // Set target buffer
        vm.prank(manager);
        uint target = numUsers * 1 ether;
        stakingManager.setTargetBuffer(target);

        // numUsers = 4 will stake first
        for(uint i = 0; i<numUsers; i++) {
            address userx = makeAddr(vm.toString(i));
            vm.deal(userx, 1 ether);
            vm.prank(userx); 
            stakingManager.stake{value: 1 ether}();
        }
        
        uint256 stakeAmount = 1 ether;
        vm.deal(user, stakeAmount*20);
        vm.startPrank(user);
        for (uint i=0; i<limit - numUsers;  i++){
            stakingManager.stake{value: stakeAmount}();
        }
        vm.stopPrank();

        // Approve and queue withdrawal
        uint stakedAmount = (limit - numUsers) * (1 ether);
        vm.startPrank(user);
        kHYPE.approve(address(stakingManager), stakedAmount);
        stakingManager.queueWithdrawal(stakedAmount);
        vm.stopPrank();

        uint256 withdrawalId = stakingManager.nextWithdrawalId(user) - 1;
        
        // Set withdrawal delay to 0 to allow immediate confirmation
        vm.prank(manager);
        stakingManager.setWithdrawalDelay(0);

        // Confirm withdrawal - use the actual hypeAmount from the request
        vm.prank(user);
        stakingManager.confirmWithdrawal(withdrawalId);

    }

    /*
Let's assume that 4,000 users each deposit 1 ETH. The target buffer is set to 1% of the limit (10,000 ETH), which equals 100 ETH. If suddenly around 150 users try to withdraw their ETH, only the first 100 users will be able to withdraw from the buffer. From user 101 onward, withdrawals will be blocked due to insufficient funds in the buffer, which was only intended to hold 100 ETH (1% of the total).
    */

    uint256 constant NUM_DEPOSITS = 150;
    function testNotAllUsersCanWithdraw() public {
        
        // Set up delegation first
        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager), validator);
        vm.stopPrank();

        // Set target buffer
        vm.prank(manager);
        uint target = 100 ether;
        stakingManager.setTargetBuffer(target);

        // Users deposit or stake 1 ether each one
        address[NUM_DEPOSITS] memory users;
        for(uint i = 0; i<NUM_DEPOSITS; i++) {
            users[i] = makeAddr(vm.toString(i+1));
            vm.deal(users[i], 1 ether);
            vm.prank(users[i]);
            stakingManager.stake{value: 1 ether}();
        }

        // Approve and queue withdrawal
        for ( uint256 j = 0; j<NUM_DEPOSITS; j++){
            vm.startPrank(users[j]);
            kHYPE.approve(address(stakingManager), 1 ether);
            stakingManager.queueWithdrawal(1 ether);
            vm.stopPrank();
        }

        // Set withdrawal delay to 0 to allow immediate confirmation
        vm.prank(manager);
        stakingManager.setWithdrawalDelay(0);

        // Only the first 100 users will be able to withdraw their ETH
        for (uint i=0; i<100; i++){
            vm.prank(users[i]);
            stakingManager.confirmWithdrawal(0);
        }

        // From user 101 onwards, withdrawals will be blocked due to insufficient funds in the buffer
        for (uint i=100; i<150; i++){
            vm.prank(users[i]);
            vm.expectRevert("Insufficient contract balance");
            stakingManager.confirmWithdrawal(0);
        }
    }
}

/*
What happens if a user deposits 0.1 eth a lot of times, then perform a batchWithdrawal of 0.01 eth each one so the for loop will incurr a lot of gas 
*/

/*
Can we assume that 40_000 users deposit 1 eth each one, target is set to 10% of limit, that is 10% of 10_000, so target will be 1_000. If suddenly more than 10_000 user withdraw his ether, say 15_000 user want to withdraw, then 5_000 will not be able to withdraw since in the buffer there is no enought eth.

Can we set the target to 1%, that is 100 eth. So if someone wants to drain it, it will only be possible to drain only 1% as maximum. So this is interesting as a way of protecting funds.
*/

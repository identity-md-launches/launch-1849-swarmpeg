// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {SwarmMaintenance} from "../src/SwarmMaintenance.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RefusingIMD is MockERC20 {
    address public refused;
    constructor() MockERC20("IMD", "IMD", 0) {}

    function refuse(address recipient) external {
        refused = recipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(to != refused, "recipient blocked");
        super._update(from, to, value);
    }
}

contract MaintenanceTest is Fixture {
    bytes32 constant WORK = keccak256("accepted on-chain renderer research artifact");

    function setUp() public {
        _setup(true, true);
        _trade(true, true, 100 ether);
        token.transfer(alice, 1_000_000 ether);
        token.transfer(bob, 20_000_000 ether);
        vm.prank(alice);
        token.approve(address(pot), type(uint256).max);
        vm.prank(bob);
        token.approve(address(pot), type(uint256).max);
    }

    function _propose() internal returns (uint256 id) {
        vm.prank(alice);
        id = pot.proposePayment(worker, 1 ether, WORK);
    }

    function _approveJob() internal returns (uint256 id) {
        id = _propose();
        vm.prank(bob);
        pot.vote(id, true, 9_000_000 ether);
    }

    function test_holderApprovedJobPaidFromClaimsAndVotesRefunded() public {
        uint256 id = _approveJob();
        assertEq(pot.managedAssets(), 2 ether);
        assertEq(pot.escrowedVotes(), 10_000_000 ether);
        assertEq(token.balanceOf(address(pot)), pot.escrowedVotes());
        vm.warp(block.timestamp + 7 days);
        assertTrue(pot.passed(id));
        vm.expectRevert(SwarmMaintenance.NotExecutable.selector);
        pot.executePayment(id);
        vm.prank(alice);
        pot.withdrawVote(id);
        vm.prank(bob);
        pot.withdrawVote(id);
        assertEq(token.balanceOf(alice), 1_000_000 ether);
        assertEq(token.balanceOf(bob), 20_000_000 ether);
        assertEq(pot.escrowedVotes(), 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(worker);
        pot.executePayment(id);
        assertEq(imd.balanceOf(worker), 1 ether);
        assertEq(pot.totalPaid(), 1 ether);
        assertEq(pot.managedAssets(), 1 ether);
        assertEq(_claims(), 1 ether);
        assertEq(pot.activeJob(), 0);
        vm.expectRevert(SwarmMaintenance.NotExecutable.selector);
        pot.executePayment(id);
        vm.expectRevert(SwarmMaintenance.NothingToWithdraw.selector);
        vm.prank(alice);
        pot.withdrawVote(id);
    }

    function test_votesLockedDuplicateAndLateVotesRefused() public {
        uint256 id = _propose();
        vm.expectRevert(SwarmMaintenance.VoteLocked.selector);
        vm.prank(alice);
        pot.withdrawVote(id);
        vm.expectRevert(SwarmMaintenance.AlreadyVoted.selector);
        vm.prank(alice);
        pot.vote(id, true, 1 ether);
        vm.expectRevert(SwarmMaintenance.JobActive.selector);
        vm.prank(bob);
        pot.proposePayment(worker, 1 ether, WORK);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(SwarmMaintenance.VotingClosed.selector);
        vm.prank(bob);
        pot.vote(id, true, 10_000_000 ether);
        assertFalse(pot.passed(id));
        pot.closeJob(id);
        assertEq(pot.activeJob(), 0);
        vm.prank(alice);
        pot.withdrawVote(id);
        assertEq(pot.escrowedVotes(), 0);
    }

    function test_majorityOppositionRejectsEvenWithQuorum() public {
        uint256 id = _propose();
        vm.prank(bob);
        pot.vote(id, true, 9_000_000 ether);
        token.transfer(worker, 11_000_000 ether);
        vm.startPrank(worker);
        token.approve(address(pot), 11_000_000 ether);
        pot.vote(id, false, 11_000_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 9 days);
        assertFalse(pot.passed(id));
        vm.expectRevert(SwarmMaintenance.NotExecutable.selector);
        pot.executePayment(id);
        pot.closeJob(id);
        assertEq(pot.totalPaid(), 0);
        assertEq(pot.managedAssets(), 2 ether);
    }

    function test_approvedJobExpiresWithoutSeizingVotes() public {
        uint256 id = _approveJob();
        vm.warp(block.timestamp + 23 days);
        vm.expectRevert(SwarmMaintenance.NotExecutable.selector);
        pot.executePayment(id);
        pot.closeJob(id);
        vm.prank(alice);
        pot.withdrawVote(id);
        vm.prank(bob);
        pot.withdrawVote(id);
        assertEq(pot.escrowedVotes(), 0);
        assertEq(pot.managedAssets(), 2 ether);
    }

    function test_invalidJobsAndUnfundedVotingRollBack() public {
        vm.startPrank(alice);
        vm.expectRevert(SwarmMaintenance.InvalidJob.selector);
        pot.proposePayment(address(0), 1, WORK);
        vm.expectRevert(SwarmMaintenance.InvalidJob.selector);
        pot.proposePayment(worker, 0, WORK);
        vm.expectRevert(SwarmMaintenance.InvalidJob.selector);
        pot.proposePayment(worker, 3 ether, WORK);
        vm.expectRevert(SwarmMaintenance.InvalidJob.selector);
        pot.proposePayment(worker, 1, bytes32(0));
        vm.stopPrank();
        uint256 id = _propose();
        vm.expectRevert();
        vm.prank(worker);
        pot.vote(id, true, 1 ether);
        (, bool voted) = pot.receipts(id, worker);
        assertFalse(voted);
        assertEq(pot.escrowedVotes(), 1_000_000 ether);
    }

    function test_callbackCannotBeForgedAndRedemptionCannotRedirect() public {
        vm.expectRevert(SwarmMaintenance.OnlyExpectedManagerCallback.selector);
        pot.unlockCallback(abi.encode(worker));
        vm.expectRevert(SwarmMaintenance.OnlyExpectedManagerCallback.selector);
        vm.prank(address(manager));
        pot.unlockCallback(abi.encode(worker));
        vm.prank(worker);
        pot.redeemFees(1 ether);
        assertEq(imd.balanceOf(worker), 0);
        assertEq(imd.balanceOf(address(pot)), 1 ether);
        assertEq(pot.managedAssets(), 2 ether);
        vm.expectRevert();
        pot.redeemFees(2 ether);
        assertEq(pot.managedAssets(), 2 ether);
    }

    function test_rejectedPairTransferRollsBackAndCanRetry() public {
        uint256 id = _approveJob();
        // Preserve ERC-20 storage; add a test-only blocked-recipient behavior.
        vm.etch(address(imd), address(new RefusingIMD()).code);
        RefusingIMD(address(imd)).refuse(worker);
        vm.warp(block.timestamp + 9 days);
        vm.expectRevert();
        pot.executePayment(id);
        assertEq(pot.activeJob(), id);
        assertEq(pot.totalPaid(), 0);
        assertEq(pot.managedAssets(), 2 ether);
        RefusingIMD(address(imd)).refuse(address(router));
        pot.executePayment(id);
        assertEq(imd.balanceOf(worker), 1 ether);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {LinkedListLib} from "../libs/LinkedList.sol";
import {IL2OutputOracle} from "./IL2OutputOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract StakingModule is OwnableUpgradeable, ReentrancyGuard, LinkedListLib {

    // @notice unstake information
    // timestamp The time since last unstake request made at
    // amount Total amount of unstake requests
    struct Unstaking {
        uint timestamp;
        uint amount;
    }

    // if isCurrentValidator = true
    // this account still can submit state root to the contract
    // and will be turn off for the next round
    struct NotInLeaderBoard {
        uint amount;
        bool isCurrentValidator;
        uint64 index;
        bool isPendingValidator;
        uint64 indexPending;
    }

    IL2OutputOracle private l2OutputOracle;
    uint public minStakeAmount;
    // prev validator in array
    address[] public prevValidators;
    // pending validator in array
    address[] public pendingValidators;
    // store current validator but currently off the top board staked token
    mapping(address => NotInLeaderBoard) public validatorNotInLeaderBoard;
    // unstaking mapping
    mapping(address => Unstaking) public unstakings;
    // unstake time
    uint public unstakingTime;

    // @dev event section
    event UpdateNumbOfValidator(uint value);
    event ClaimUnstaked(address, uint);
    event Stake(address, uint);
    event UpdateL2OutputOracle(address);
    event UpdateMinStakeAmount(uint);
    event UpdateValidatorList(address[], address[]);
    event Unstake(address, uint, uint);
    event ClaimTopValidator(address[]);

    // @dev error section
    error InvalidStakingAmount();
    error InvalidNumbOfValidator();
    error InvalidInitValidatorData();
    error ValidatorValueMustNotZero();
    error DuplicatedValidator();
    error AmountNotSorted();
    error StakeAmountNotEqualMsgValue();
    error UnstakingTimeMustNotBeZero();
    error CanNotClaimAmountIsZeroOrTimeNotReached();
    error MinimumMustNotZero();
    error OnlyL2OutputOracle();
    error TransferTokenFailed();
    error FailedLogic();
    error UnstakeAmountMustNotBeZero();
    error InsufficientBalance();
    error FailedToWithdrawAmount();
    error MustWithdrawToZeroOrLeftAmountGreaterThanMin();
    error ValidatorsMustNotEmpty();
    error StakerIsInTopOrNotHaveStakeYet();

    function initialize(
        uint256 minStakeAmount_,
        uint maxValidator_,
        uint unstakingTime_,
        address[] calldata initValidators_,
        uint[] calldata amounts_
    ) payable external initializer {
        if (unstakingTime_ == 0) {
            revert UnstakingTimeMustNotBeZero();
        }

        // the number of init validators must equal to stake amount data size
        // init data must not be empty
        // number of validators must not be greater than max configuration
        if (initValidators_.length != amounts_.length || initValidators_.length == 0 || initValidators_.length > maxValidator_) {
            revert InvalidInitValidatorData();
        }

        // add to stake list
        uint totalStaked;
        uint lastStakeAmount;
        for (uint i = 0; i < initValidators_.length; i++) {
            uint stakeAmount = amounts_[i];
            if (initValidators_[i] == address(0) || stakeAmount == 0) {
                revert ValidatorValueMustNotZero();
            }

            // init data must not be sorted
            if (lastStakeAmount < stakeAmount) {
                revert AmountNotSorted();
            }

            // check duplicate
            if (getIdByAddress(initValidators_[i]) != 0) {
                revert DuplicatedValidator();
            }

            // add to stake list
            addInitNode(initValidators_[i], stakeAmount);
            totalStaked += stakeAmount;
            lastStakeAmount = stakeAmount;
        }

        // total stake must equal msg.value
        if (totalStaked != msg.value) {
            revert StakeAmountNotEqualMsgValue();
        }

        // the total staked in data must equal to the msg.value
        __Ownable_init();
        MAX_VALIDATOR = uint16(maxValidator_);
        minStakeAmount = minStakeAmount_;
        unstakingTime = unstakingTime_;
    }

    // handle stake internally
    function handleStakeRequest(address staker, uint stakeAmount) internal {
        NotInLeaderBoard storage validatorInfo = validatorNotInLeaderBoard[staker];
        unchecked {
            if (validatorInfo.amount > 0) {
                stakeAmount += validatorInfo.amount;
                validatorInfo.amount = 0;
            }
        }
        (address removedAddr, uint256 removedAmount) = addNodeSorted(staker, stakeAmount);
        if (removedAddr != address(0)) {
            if (removedAddr == staker) {
                validatorInfo.amount = stakeAmount;
            } else {
                if (validatorInfo.isCurrentValidator) {
                    // remove from prevValidators array
                    // assign removed item for the last item
                    prevValidators[validatorInfo.index] = prevValidators[prevValidators.length - 1];
                    // assign new index for the last item
                    validatorNotInLeaderBoard[prevValidators[validatorInfo.index]].index = validatorInfo.index;
                    // remove last item out of the array
                    prevValidators.pop();
                    // update validator info
                    validatorInfo.isCurrentValidator = false;
                    validatorInfo.index = 0;
                } else {
                    // update this is pending validator for the next round
                    validatorInfo.isPendingValidator = true;
                    //  update this validator to the pending array for used later
                    validatorInfo.indexPending = uint64(pendingValidators.length);
                    prevValidators.push(removedAddr);
                }

                // handle validator dropped from dashboard
                NotInLeaderBoard storage validatorDroppedInfo = validatorNotInLeaderBoard[removedAddr];
                if (validatorDroppedInfo.isPendingValidator) {
                    // assign removed item for the last item
                    pendingValidators[validatorDroppedInfo.indexPending] = pendingValidators[pendingValidators.length - 1];
                    // assign new index for the last item
                    validatorNotInLeaderBoard[pendingValidators[validatorDroppedInfo.indexPending]].indexPending = validatorDroppedInfo.indexPending;
                    // remove last item out of the array
                    pendingValidators.pop();
                    // update validator info
                    validatorDroppedInfo.isPendingValidator = false;
                    validatorDroppedInfo.indexPending = 0;
                } else {
                    validatorDroppedInfo.isCurrentValidator = true;
                    validatorDroppedInfo.index = uint64(prevValidators.length);
                    prevValidators.push(removedAddr);
                }
                validatorDroppedInfo.amount = removedAmount;

                // sanity check before complete transaction
                if (validatorDroppedInfo.isPendingValidator && validatorDroppedInfo.isCurrentValidator ||
                    validatorInfo.isPendingValidator && validatorInfo.isCurrentValidator
                ) {
                    revert FailedLogic();
                }
            }
        }

        emit Stake(staker, stakeAmount);
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * @dev User call function to stake their fund into staking pool
     * staking amount must > Y TC tokens
     * update user will be validator at the next chunk if reach condition
     * - stake amount in top N
     * - state root has 2/3 to re-update committee
     */
    function staking() payable external nonReentrant {
        uint256 stakeAmount = msg.value;
        // check if stake amount is greater than minimum
        if (stakeAmount < minStakeAmount) {
            revert InvalidStakingAmount();
        }

        // update stake amount
        address staker = msg.sender;

        // trigger stake logic
        // state change from here
        handleStakeRequest(staker, stakeAmount);
    }

    /**
     * @notice Validator withdraw their staked token
     * @dev
     */
    function updateCommitteeList() external nonReentrant {
        // only l2OutputOracle can trigger update validator list
        if (msg.sender != address(l2OutputOracle)) {
            revert OnlyL2OutputOracle();
        }

        address[] memory oldValidators = prevValidators;
        address[] memory newValidatorsAdded = pendingValidators;

        // loop through pending validators and update
        // previous validator list
        for (uint i = 0; i < prevValidators.length; i++) {
            address temp = prevValidators[i];
            validatorNotInLeaderBoard[temp].isCurrentValidator = false;
            validatorNotInLeaderBoard[temp].index = 0;
        }

        // pending validators list
        for (uint i = 0; i < pendingValidators.length; i++) {
            address temp = pendingValidators[i];
            validatorNotInLeaderBoard[temp].isPendingValidator = false;
            validatorNotInLeaderBoard[temp].index = 0;
        }

        // reset values
        prevValidators = new address[](0);
        pendingValidators = prevValidators;

        emit UpdateValidatorList(oldValidators, newValidatorsAdded);
    }

    /**
     * @notice
     * @dev This will reupdate the top of list staker when some of top staker do
     * unstake and their stake amount not be in top
     * so anyone trigger this function to bring them back to the top
     */
    function claimTopValidator(address[] memory stakers_) payable external nonReentrant {
        if (stakers_.length == 0) {
            revert ValidatorsMustNotEmpty();
        }

        for (uint i = 0; i < stakers_.length; i++) {
            // verify staker not in the top list
            if (getIdByAddress(stakers_[i]) != 0 || validatorNotInLeaderBoard[stakers_[i]].amount == 0) {
                revert StakerIsInTopOrNotHaveStakeYet();
            }

            handleStakeRequest(stakers_[i], 0);
        }

        emit ClaimTopValidator(stakers_);
    }

    /**
     * @notice Validator withdraw their staked token
     * @dev
     */
    function unstaking(uint unstakeAmount_) payable external nonReentrant {
        if (unstakeAmount_ == 0) {
            revert UnstakeAmountMustNotBeZero();
        }

        address staker = msg.sender;
        // check if sender is not in top leader board
        NotInLeaderBoard storage validatorDroppedInfo = validatorNotInLeaderBoard[staker];
        // if user off the top leader board then handle
        if (validatorDroppedInfo.amount >= unstakeAmount_) {
            unchecked {
                validatorDroppedInfo.amount -= unstakeAmount_;
            }
        } else if (getNodeByAddress(staker).amount >= unstakeAmount_) {
            // store current node in memory
            Node memory node = getNodeByAddress(staker);
            uint leftAmount = node.amount - unstakeAmount_;
            if (leftAmount > 0 && leftAmount < minStakeAmount) {
                revert MustWithdrawToZeroOrLeftAmountGreaterThanMin();
            }
            // remove node from list board
            removeNode(getIdByAddress(staker));
            if (leftAmount > 0) {
                handleStakeRequest(staker, leftAmount);
            }
        } else {
            revert InsufficientBalance();
        }

        // update unstaking request
        unstakings[staker].timestamp = block.timestamp;
        unstakings[staker].amount += unstakeAmount_;

        emit Unstake(staker, block.timestamp, unstakeAmount_);
    }

    // todo cast vote
    // todo store amount vote at block height

    /**
     * @notice Unstaker claim staked token by trigger this function
     * @dev if the unstaked request passed unstake period can claim token
     */
    function claim() external nonReentrant {
        // check caller has unstake value > 0 and pased unstaking period
        Unstaking storage unstakingInfo = unstakings[msg.sender];
        if (unstakingInfo.amount == 0 || block.timestamp - unstakingInfo.timestamp < unstakingTime) {
            revert CanNotClaimAmountIsZeroOrTimeNotReached();
        }
        uint claimAmount = unstakingInfo.amount;
        unstakingInfo.amount = 0;
        (bool success,) = msg.sender.call{value: claimAmount}("");
        if (!success) {
            revert TransferTokenFailed();
        }

        emit ClaimUnstaked(msg.sender, claimAmount);
    }

    /**
     * @dev update contract address
     */
    function updateL2Output(address l2OutputOracle_) external onlyOwner {
        // sanity check
        IL2OutputOracle(l2OutputOracle_).FINALIZATION_PERIOD_SECONDS();
        // update state
        l2OutputOracle = IL2OutputOracle(l2OutputOracle_);

        emit UpdateL2OutputOracle(l2OutputOracle_);
    }

    /**
     * @dev update number of validators
     */
    function updateNumbOfValidators(uint numbOfValidators_) external onlyOwner {
        if (numbOfValidators_ == 0) {
            revert InvalidNumbOfValidator();
        }
        MAX_VALIDATOR = numbOfValidators_;

        emit UpdateNumbOfValidator(numbOfValidators_);
    }

    /**
     * @dev update minimum stake value
     */
    function updateMinStakeAmount(uint minimumStake_) external onlyOwner {
        if (minimumStake_ == 0) {
            revert MinimumMustNotZero();
        }
        minStakeAmount = minimumStake_;

        emit UpdateMinStakeAmount(minimumStake_);
    }


    // @dev getter functions

    /**
     * @dev to query and get latest and next block height
     */
    function isCurrentValidator(address validator_) external returns(bool) {
        return true;
    }

    /**
     * @dev list validator
     */
    function getValidators() external returns(address[] memory) {
        return new address[](1);
    }
}

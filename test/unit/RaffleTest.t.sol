//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
     event EnteredRaffle(
        address indexed player
    );

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;
    uint256 deployerKey;
    Raffle raffle;
    HelperConfig helperConfig;
    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_BALANCE = 10 ether;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link,
            deployerKey
        ) = helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    ///////////////////////
    // enterRaffle      //
    /////////////////////


    function testRaffleRevertsWhenYouDontPayEnough() public {
        //Arrange
        vm.prank(PLAYER);
        //Act
        vm.expectRevert(Raffle.Raffle__NotEnoughEth.selector);
        raffle.enterRaffle();
    }

    function testRaffleIsCalculatingCantEnter() public {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        //pass time
        vm.warp(block.timestamp + interval + 1);
        // pass block
        vm.roll(block.number + 1);
        //Act
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__NotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        
    }

    function testRaffleRcordPlayer() public {
        //Arrange
        vm.prank(PLAYER);
        //Act
        raffle.enterRaffle{value: entranceFee}();
        address player = raffle.getPlayer(0);
        assert(player == PLAYER);
    }

    function testEmitsEventOnEntrance() public {
        //assert
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        // we need to manually emit 
        //arrange
        emit EnteredRaffle(PLAYER);
        
        //act
        raffle.enterRaffle{value: entranceFee}();
    }


    ///////////////////////
    // checkUpkeep      //
    /////////////////////

    function testCheckUpKeepReturnsFalseIfNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        //assert
        assert(!upkeepNeeded);
    }

    function testCheckUpKeepReturnsFalseIfNotOpened() public {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        //pass time
        vm.warp(block.timestamp + interval + 1);
        // pass block
        vm.roll(block.number + 1);
        //Act

        //we perform the upkeep so we get in calculating state
        raffle.performUpkeep("");
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        //assert
        assert(!upkeepNeeded);
    }

    function testPerformUpkeepReverts() public {
        uint256 currBalance = 0;
        uint256 numPlayers = 0;
        uint256 raffleState = 0;
        //not enough time has passed
        vm.expectRevert(abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, currBalance, numPlayers, raffleState));
        raffle.performUpkeep("");
    }

    modifier RaffleEnteredAndTimePassed {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();

        //pass time
        vm.warp(block.timestamp + interval + 1);
        // pass block
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId()
        public RaffleEnteredAndTimePassed {
        //Act
        vm.recordLogs();

        raffle.performUpkeep(""); //emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        assert(uint256(requestId) > 0);

    }

    ///////////////////////
    // fulfillRandomWords//
    /////////////////////

    function testFulfiullRandomWordsOnlyBeCalledAfterPerformUpkeep(
        uint256 randomRequestId
    )
        public
        RaffleEnteredAndTimePassed
        skipFork
    {
        //Arrange
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            randomRequestId,
            address(raffle)
        );
        //do some fuzzing
    }

    function testFulfilRandomWordsPicksAWinnerResetsAndSendsMoney()
        public RaffleEnteredAndTimePassed skipFork {
        //arrange
        uint256 additionalEntrance = 5;
        uint256 startingIndex = 1;
        //fund raffle
        for(uint256 i = startingIndex; i < startingIndex + additionalEntrance; i++) {
            address player = address(uint160(i)); //address 1, 2, 3 etc
            hoax(player, STARTING_BALANCE);
            // vm.prank(player);
            raffle.enterRaffle{value: entranceFee}();
        }

        //pretend to be vrf coordinator
        vm.recordLogs();
        uint256 prize = entranceFee * (additionalEntrance + 1);
        raffle.performUpkeep(""); //emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimeStamp = raffle.getLastTimeStamp();

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );

        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getLenghtOfPlayers() == 0);
        assert(previousTimeStamp < raffle.getLastTimeStamp());
        assert(raffle.getRecentWinner().balance == STARTING_BALANCE + prize - entranceFee);
    }
}
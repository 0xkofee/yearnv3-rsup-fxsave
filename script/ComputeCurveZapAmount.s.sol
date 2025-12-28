// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import {SreUSDCrvUSDLoopStrategy} from "../src/SreUSDCrvUSDLoopStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurveController {
    function user_state(address user) external view returns (uint256[4] memory);
}

/**
 * @notice Compute Curve collateral amount after a deposit for zap route sizing.
 * @dev Run with ANVIL_RPC_URL=http://localhost:8545 forge script script/ComputeCurveZapAmount.s.sol -vvv
 */
contract ComputeCurveZapAmount is Script, Test {
    address public constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address public constant SREUSD = 0x557AB1e003951A73c12D16F0fEA8490E39C33C35;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant CURVE_LLAMMA = 0x4F79Fe450a2BAF833E8f50340BD230f5A3eCaFe9;
    address public constant RESUPPLY_PAIR = 0xD42535Cda82a4569BA7209857446222ABd14A82c;
    address public constant SWAPPER = 0x3Ae884D1a67650501278001FDa40DCa975D9194D;
    address public constant CURVE_ZAP = 0xC5898606BdB494a994578453B92e7910a90aA873;

    uint256 public constant INITIAL_DEPOSIT = 10000 ether;
    uint256 public constant DEFAULT_FORK_BLOCK = 24100306;

    function run() external {
        string memory rpcUrl = vm.envOr("ANVIL_RPC_URL", string("http://localhost:8545"));
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        vm.createSelectFork(rpcUrl, forkBlock);

        SreUSDCrvUSDLoopStrategy loopStrategy = new SreUSDCrvUSDLoopStrategy(
            REUSD,
            SREUSD,
            CRVUSD,
            CURVE_LLAMMA,
            RESUPPLY_PAIR,
            "SreUSD Loop Strategy"
        );

        IStrategy strategyVault = IStrategy(address(loopStrategy));

        address user = address(0xBEEF);
        deal(REUSD, user, 20000 ether, true);

        vm.startPrank(user);
        IERC20(REUSD).approve(address(loopStrategy), INITIAL_DEPOSIT);
        strategyVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        uint256[4] memory state = ICurveController(CURVE_LLAMMA).user_state(address(loopStrategy));
        console2.log("collateral", state[0]);
        console2.log("debt", state[2]);
    }
}

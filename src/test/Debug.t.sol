// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/Test.sol";

interface IResupply {
    function borrow(
        uint256 _borrowAmount,
        uint256 _underlyingAmount,
        address _receiver
    ) external returns (uint256 _shares);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract DebugTest is Test {
    address public constant RESUPPLY_PAIR = 0xD42535Cda82a4569BA7209857446222ABd14A82c;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    
    // 0x1010... address
    address public constant DEPLOYER = 0x10101010E0C3171D894B71B3400668aF311e7D94;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("http://localhost:8545"));
        vm.createSelectFork(rpcUrl);
    }

    function testDebugBorrow() public {
        emit log_named_address("RESUPPLY_PAIR address", RESUPPLY_PAIR);

        // Deal crvUSD
        deal(CRVUSD, address(this), 1000e18);
        IERC20(CRVUSD).approve(RESUPPLY_PAIR, type(uint256).max);

        // Try borrow
        // Borrow 1 reUSD against 10 crvUSD (just valid params hopefully)
        // Need to know LTV to be safe.
        // Strategy uses 92% LTV.
        // If I use small borrow amount it should be fine.

        try IResupply(RESUPPLY_PAIR).borrow(1e18, 10e18, address(this)) {
            emit log("Borrow success");
        } catch Error(string memory reason) {
            emit log_named_string("Borrow failed with reason", reason);
        } catch (bytes memory) {
            emit log("Borrow failed with low level data");
        }
    }
}

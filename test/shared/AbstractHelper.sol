// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/interfaces/ICDP.sol";
import "./interfaces/IHelper.sol";
import "./ForkTests.sol";
import "../mocks/interfaces/IMockOracle.sol";
import "../SetupContract.sol";

abstract contract AbstractHelper is IHelper, AbstractForkTest, SetupContract {
    function setPools(ICDP vault) public {
        address[] memory pools = new address[](3);

        pools[0] = getPool(wbtc, usdc);
        pools[1] = getPool(weth, usdc);
        pools[2] = getPool(wbtc, weth);

        for (uint256 i = 0; i < 3; ++i) {
            vault.setPoolParams(pools[i], ICDP.PoolParams(0.7 gwei, 0.6 gwei, 0));
        }
    }

    function setTokenPrice(
        IMockOracle oracle,
        address token,
        uint256 newPrice
    ) public {
        oracle.setPrice(token, newPrice);
        if (token != usdc && newPrice != 0) {
            // align to USDC decimals
            makeDesiredUSDCPoolPrice(newPrice / 10**12, token);
        }
    }

    function makeDesiredUSDCPoolPrice(uint256 targetPriceX96, address token) public virtual;

    function getPool(address token0, address token1) public virtual returns (address pool);

    function setApprovals() public {
        IERC20(wbtc).approve(PositionManager, type(uint256).max);
        IERC20(weth).approve(PositionManager, type(uint256).max);
        IERC20(weth).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(PositionManager, type(uint256).max);
        IERC20(dai).approve(PositionManager, type(uint256).max);
    }
}

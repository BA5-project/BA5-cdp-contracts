// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "@solmate/src/tokens/ERC20.sol";
import "./libraries/ExceptionsLibrary.sol";

contract MUSD is ERC20 {
    address public immutable governingVault;

    constructor(
        string memory name,
        string memory symbol,
        address vault
    ) ERC20(name, symbol, 18) {
        governingVault = vault;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != governingVault) {
            revert ExceptionsLibrary.Forbidden();
        }
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != governingVault) {
            revert ExceptionsLibrary.Forbidden();
        }
        _burn(from, amount);
    }
}
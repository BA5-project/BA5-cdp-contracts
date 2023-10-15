// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@LayerZero/token/oft/v2/OFTV2.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import '@zkbob/token/ERC677.sol';
import '@zkbob/token/ERC20Permit.sol';
import '@openzeppelin/contracts/access/Ownable.sol';


/// @title A LayerZero OmnichainFungibleToken example of BasedOFT
/// @notice Use this contract only on the BASE CHAIN. It locks tokens on source, on outgoing send(), and unlocks tokens when receiving from other chains.
contract EclypseUSD is OFTV2, ERC20Burnable {

    error EUSD__AmountMustBeMoreThanZero();
    error EUSD__BurnAmountExceedsBalance();
    error EUSD__NotZeroAddress();
    
    constructor(address _layerZeroEndpoint, uint _initialSupply, uint8 _sharedDecimals, address newOwner) OFTV2("EclypseUSD", "EUSD", _sharedDecimals, _layerZeroEndpoint) {
        _mint(_msgSender(), _initialSupply);
        transferOwnership(newOwner);
    }

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool){
         if (_to == address(0)) {
            revert EUSD__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert EUSD__AmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert EUSD__AmountMustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert EUSD__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

}

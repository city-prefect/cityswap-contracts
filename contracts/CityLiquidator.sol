// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev CityLiquidator contract locks the liquidity (LP tokens) which are added by the double automatic liquidity :
 * 1. From CitySwapToken : when swapAndLiquify
 * 2. From deposit fees tax rate : when deposit on a single downtown pool with depositFeeTax > 0
 *
 * Lps are locked in this contract so we can migrate the LPs if there are any new versions of LP in the future
 */
contract CityLiquidator is Ownable {
    using SafeBEP20 for IBEP20;

    event Unlocked(address indexed token, address indexed recipient, uint256 amount);

    function unlock(IBEP20 _token, address _recipient) public onlyOwner {
        require(_recipient != address(0), "CityLiquidator::unlock: ZERO address.");

        uint256 amount = _token.balanceOf(address(this));
        _token.safeTransfer(_recipient, amount);
        emit Unlocked(address(_token), _recipient, amount);
    }
}

pragma solidity >=0.5.0;
import './IERC20.sol';

interface IHcToken is IERC20 {
    function originAddress() external view returns(address);
    function superMint(address to_,uint256 amount_) external;
    function transferOwnership(address newOwner) external;
    function burn(uint256 amount_) external;
}

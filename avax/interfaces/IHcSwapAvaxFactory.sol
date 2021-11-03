pragma solidity >=0.5.0;

interface IHcSwapAvaxFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function owner() external view returns (address);
    function setOwner(address _owner) external;
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);
    function createAToken(string calldata name,string calldata symbol,uint8 decimals,address originAddress_) external returns(address token);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

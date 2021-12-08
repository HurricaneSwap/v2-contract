pragma solidity =0.6.6;
pragma experimental ABIEncoderV2;

import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IHcSwapAvaxFactory.sol';
import './libraries/TransferHelper.sol';
import '../public/libraries/LPQueue.sol';
import './interfaces/IUniswapV2Router02.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IHcToken.sol';
import './interfaces/IWETH.sol';
import './interfaces/IUniswapV2Pair.sol';
import './interfaces/IHcSwapAvaxPair.sol';
import './interfaces/IHcTokenFactory.sol';
import '../public/contract/Pausable.sol';
import "openzeppelin3/proxy/Initializable.sol";

contract HcSwapAvaxRouter is IUniswapV2Router02, Pausable, Initializable {
    using SafeMath for uint;

    address public override factory;
    address public override WETH;
    address public tokenFactory;

    address public owner;
    mapping(address => bool) public operator;
    mapping(address => address) public BSCToAvax;
    mapping(address => bool) public crossToken;

    uint256 public tasksIndex;
    enum CrossActionStatus{FAIL, SUCCESS, CROSS_EXPIRED, INSUFFICIENT_A_AMOUNT, INSUFFICIENT_B_AMOUNT, NO_PAIR}

    struct TokenInfo {
        address originAddress;// address from BSC
        string name;
        string symbol;
        uint8 decimal;
        uint256 amount;//init amount
        address specialAddress;// use custom token address
    }

    struct CrossAction {
        uint8 actionType; // 0 sync amount 1 mint lp 2 burn lp
        bytes32 checksum;//important!
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 liquidity;// when type is sync, this field will be zero.
    }

    //status 0 = fail 1 = success >1=fail with message
    event CrossActionDone(uint256 indexed id, CrossActionStatus status, CrossAction result);
    event CrossLiquidityCreated(address indexed pair, uint liquidity, TokenInfo tokenA, TokenInfo tokenB);

    modifier onlyOwner(){
        require(msg.sender == owner, "HcSwapV2Router: ONLY_OWNER");
        _;
    }

    modifier onlyOperator(){
        require(isOperator(), "HcSwapV2Router:ONLY_OPERATOR");
        _;
    }

    function isOperator() public view returns (bool){
        return operator[msg.sender] || msg.sender == owner;
    }

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'HcSwapV2Router: EXPIRED');
        _;
    }

    function setOwner(address _owner) onlyOwner public {
        owner = _owner;
    }

    function setFactoryOwner(address _owner) onlyOwner public {
        if (IHcSwapAvaxFactory(factory).owner() == address(this)) {
            IHcSwapAvaxFactory(factory).setOwner(_owner);
        }
    }

    function setPause(bool _status) onlyOwner public {
        if (_status && !paused()) {
            _pause();
        }

        if (!_status && paused()) {
            _unpause();
        }
    }

    function setCrossToken(address[] memory _token, bool[] memory _status) onlyOwner public {
        require(_token.length == _status.length, "HcSwapV2Router:SET_CROSS_TOKEN_WRONG_DATA");
        for (uint i = 0; i < _token.length; i++) {
            crossToken[_token[i]] = _status[i];
        }
    }

    function setBscToAvax(address[] memory _tokenBsc, address[] memory _tokenAvax) onlyOwner public {
        require(_tokenBsc.length == _tokenAvax.length, "HcSwapAvaxRouter: SET_BSC_AVAX_WRONG_DATA");
        for (uint i = 0; i < _tokenBsc.length; i++) {
            BSCToAvax[_tokenBsc[i]] = _tokenAvax[i];
        }
    }

    function setOperator(address[] memory _ops, bool[] memory _status) onlyOwner public {
        require(_ops.length == _status.length, "HcSwapV2Router:SET_OPERATOR_WRONG_DATA");
        for (uint i = 0; i < _ops.length; i++) {
            operator[_ops[i]] = _status[i];
        }
    }

    constructor() public initializer {}

    function initialize(address _factory, address _WETH, address _tokenFactory) public initializer{
        factory = _factory;
        WETH = _WETH;
        tokenFactory = _tokenFactory;
        owner = msg.sender;
        tasksIndex = 1;
    }

    receive() external payable {
        require(msg.sender == WETH);
        // only accept ETH via fallback from the WETH contract
    }

    // **** CROSS ACTION ****
    function initBSCToken(TokenInfo memory token) internal returns (address tokenAddress){
        tokenAddress = BSCToAvax[token.originAddress] == address(0) ? token.specialAddress : BSCToAvax[token.originAddress];
        if (tokenAddress != address(0)) {
            if (crossToken[tokenAddress]) {
                IHcToken(tokenAddress).superMint(address(this), token.amount);
            } else {
                TransferHelper.safeTransferFrom(tokenAddress, msg.sender, address(this), token.amount);
            }
        } else {
            tokenAddress = IHcTokenFactory(tokenFactory).createAToken(token.name, token.symbol, token.decimal, token.originAddress);
            crossToken[tokenAddress] = true;
            IHcToken(tokenAddress).superMint(address(this), token.amount);
            IHcToken(tokenAddress).transferOwnership(owner);
        }
        BSCToAvax[token.originAddress] = tokenAddress;
    }

    function CreateBSCCrossLiquidity(TokenInfo memory tokenA, TokenInfo memory tokenB) onlyOperator public {
        address tokenAAddress = initBSCToken(tokenA);
        address tokenBAddress = initBSCToken(tokenB);

        require(IUniswapV2Factory(factory).getPair(tokenAAddress, tokenBAddress) == address(0));
        IUniswapV2Factory(factory).createPair(tokenAAddress, tokenBAddress);
        address pair = UniswapV2Library.pairFor(factory, tokenAAddress, tokenBAddress);
        IHcSwapAvaxPair(pair).setCrossPair(true);

        TransferHelper.safeTransfer(tokenAAddress, pair, tokenA.amount);
        TransferHelper.safeTransfer(tokenBAddress, pair, tokenB.amount);
        uint liquidity = IUniswapV2Pair(pair).mint(msg.sender);
        emit CrossLiquidityCreated(pair, liquidity, tokenA, tokenB);
    }

    function onCrossTask(LPQueue.LPAction[] memory actions, uint256[] memory ids) onlyOperator public {
        require(actions.length == ids.length, 'HcSwapV2RouterAvax:WRONG_DATA');

        for (uint i = 0; i < actions.length; i++) {
            uint current = ids[i];
            require(current == tasksIndex, 'HcSwapV2RouterAvax:WRONG_INDEX');
            LPQueue.LPAction memory action = actions[i];
            require(LPQueue.checkData(action), "HcSwapV2RouterAvax:WRONG_CHECKSUM");

            if (action.addLP) {
                (address tokenA, address tokenB, uint amountA, uint amountB, uint liquidity, CrossActionStatus success) = onAddLPCrossTask(action);
                onEmitCrossAction(current, action.checksum, true, tokenA, tokenB, amountA, amountB, liquidity, success);
            } else {
                (address tokenA, address tokenB, uint amountA, uint amountB, uint liquidity, CrossActionStatus success) = onRemoveLPCrossTask(action);
                onEmitCrossAction(current, action.checksum, false, tokenA, tokenB, amountA, amountB, liquidity, success);
            }

            tasksIndex++;
        }
    }

    function onAddLPCrossTask(LPQueue.LPAction memory action) internal returns (address tokenA, address tokenB, uint amountA, uint amountB, uint liquidity, CrossActionStatus success){
        (address bscTokenA, address bscTokenB,uint amountADesired,uint amountBDesired,uint amountAMin,uint amountBMin,,uint deadline) = LPQueue.decodeAddLP(action.payload);
        (tokenA, tokenB) = _mappingBSCTokenToAvax(bscTokenA, bscTokenB);
        // require(deadline >= block.timestamp, 'HcSwapV2Router: CROSS_EXPIRED');
        if (deadline >= block.timestamp) {
            address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
            require(pair != address(0), "HcSwapV2Router::onRemoveLPCrossTask: NO_PAIR");

            (amountA, amountB, success) = _addLiquidityNoRevert(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
            if (success == CrossActionStatus.SUCCESS) {
                IHcToken(tokenA).superMint(pair, amountA);
                IHcToken(tokenB).superMint(pair, amountB);
                liquidity = IUniswapV2Pair(pair).mint(msg.sender);
            }
        } else {
            success = CrossActionStatus.CROSS_EXPIRED;
        }
        return (bscTokenA, bscTokenB, amountA, amountB, liquidity, success);
    }

    function onRemoveLPCrossTask(LPQueue.LPAction memory action) internal returns (address tokenA, address tokenB, uint amountA, uint amountB, uint liquidity, CrossActionStatus success){
        uint amountAMin;
        uint amountBMin;
        uint deadline;
        address bscTokenA;
        address bscTokenB;
        (bscTokenA, bscTokenB, liquidity, amountAMin, amountBMin,, deadline) = LPQueue.decodeRemoveLP(action.payload);
        (tokenA, tokenB) = _mappingBSCTokenToAvax(bscTokenA, bscTokenB);

        if (deadline >= block.timestamp) {
            address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
            require(pair != address(0), "HcSwapV2Router::onRemoveLPCrossTask: NO_PAIR");

            (uint amount0, uint amount1) = IHcSwapAvaxPair(pair).burnQuery(liquidity);
            (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
            (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
            if (amountA >= amountAMin && amountB >= amountBMin) {
                IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
                // send liquidity to pair
                (amount0, amount1) = IUniswapV2Pair(pair).burn(address(this));
                (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
                // require(amount0 == amountAMin, "HcSwapV2Router::onRemoveLPCrossTask: AMOUNT0_WRONG");
                // require(amount1 == amountBMin, "HcSwapV2Router::onRemoveLPCrossTask: AMOUNT1_WRONG");
                IHcToken(tokenA).burn(amountA);
                IHcToken(tokenB).burn(amountB);
                success = CrossActionStatus.SUCCESS;
            } else {
                if (amountA < amountAMin) {
                    success = CrossActionStatus.INSUFFICIENT_A_AMOUNT;
                }

                if (amountB < amountBMin) {
                    success = CrossActionStatus.INSUFFICIENT_B_AMOUNT;
                }
            }
        } else {
            success = CrossActionStatus.CROSS_EXPIRED;
        }
        return (bscTokenA, bscTokenB, amountA, amountB, liquidity, success);
    }

    function onEmitCrossAction(uint id, bytes32 checksum, bool addLP, address tokenA, address tokenB, uint amountA, uint amountB, uint liquidity, CrossActionStatus success) internal {
        emit CrossActionDone(id, success, CrossAction({
        actionType : addLP ? 1 : 2,
        checksum : checksum,
        tokenA : tokenA,
        tokenB : tokenB,
        amountA : amountA,
        amountB : amountB,
        liquidity : liquidity
        }));
    }

    function _mappingBSCTokenToAvax(address bscTokenA, address bscTokenB) internal view returns (address tokenA, address tokenB){
        tokenA = BSCToAvax[bscTokenA];
        tokenB = BSCToAvax[bscTokenB];
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        // create the pair if it doesn't exist yet
        if (pair == address(0)) {
            require(!(crossToken[tokenA] && crossToken[tokenB]), "HcSwapV2Router::_addLiquidity CROSS_TOKEN_NOT_ALLOW_CREATE");
            pair = IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        if (IHcSwapAvaxPair(pair).crossPair()) {
            require(isOperator(), "HcSwapV2Router::_addLiquidity ONLY_OP_CAN_ADD_CROSS_LP");
        }

        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'HcSwapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'HcSwapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _addLiquidityNoRevert(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual view returns (uint amountA, uint amountB, CrossActionStatus success){
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            return (amountA, amountB, CrossActionStatus.NO_PAIR);
        }
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                // require(amountBOptimal >= amountBMin, 'HcSwapV2Router: INSUFFICIENT_B_AMOUNT');
                if (amountBOptimal < amountBMin) {
                    return (amountA, amountB, CrossActionStatus.INSUFFICIENT_B_AMOUNT);
                }
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                // assert(amountAOptimal <= amountADesired);
                // require(amountAOptimal >= amountAMin, 'HcSwapV2Router: INSUFFICIENT_A_AMOUNT');
                if (amountAOptimal > amountADesired || amountAOptimal < amountAMin) {
                    return (amountA, amountB, CrossActionStatus.INSUFFICIENT_A_AMOUNT);
                }
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
        success = CrossActionStatus.SUCCESS;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) whenNotPaused returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) whenNotPaused returns (uint amountToken, uint amountETH, uint liquidity) {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value : amountETH}();
        require(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IUniswapV2Pair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) whenNotPaused returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        // send liquidity to pair
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'HcSwapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'HcSwapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) whenNotPaused returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) whenNotPaused returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'HcSwapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) whenNotPaused returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'HcSwapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    virtual
    override
    payable
    ensure(deadline)
    whenNotPaused
    returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'HcSwapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'HcSwapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value : amounts[0]}();
        require(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }

    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    external
    virtual
    override
    ensure(deadline)
    whenNotPaused
    returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'HcSwapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'HcSwapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    virtual
    override
    ensure(deadline)
    whenNotPaused
    returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'HcSwapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'HcSwapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
    external
    virtual
    override
    payable
    ensure(deadline)
    whenNotPaused
    returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'HcSwapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'HcSwapV2Router: EXCESSIVE_INPUT_AMOUNT');
        IWETH(WETH).deposit{value : amounts[0]}();
        require(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }
}

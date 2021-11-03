pragma solidity =0.6.6;
pragma experimental ABIEncoderV2;

import './interfaces/IHcSwapBSCFactory.sol';
import './libraries/TransferHelper.sol';

import './interfaces/IHcSwapBSC.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
import './interfaces/IHcSwapBSCPair.sol';
import '../public/libraries/LPQueue.sol';
import '../public/contract/Pausable.sol';

contract HcSwapV2Router02 is IHcSwapBSC, Pausable {
    using SafeMath for uint;
    using LPQueue for LPQueue.Store;

    address public immutable override factory;
    address public immutable override WETH;

    address public owner;
    mapping(address => bool) public operator;
    mapping(address => uint) public minAmount;

    uint private unlocked = 1;

    LPQueue.Store public tasks;

    struct CrossAction {
        uint8 actionType; // 0 sync amount 1 mint lp 2 burn lp
        bytes32 checksum;//important!
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 liquidity;// when type is sync, this field will be zero.
        bool success;
    }

    function getTask(uint256 id) public view returns (LPQueue.LPAction memory) {
        return tasks.queue[id];
    }

    event CrossLiquidity(uint256 indexed id, bytes32 indexed checksum, bool addLP, LPQueue.LPAction action);
    event CreateCrossLP(address indexed pair, address token0, address token1, uint amount0, uint amount1);
    event CrossTaskDone(uint256 indexed id, bool addLP, bool success);

    function isOperator(address sender) public view returns (bool){
        return operator[sender] || sender == owner;
    }

    modifier lock() {
        require(unlocked == 1, 'HcSwap: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    modifier onlyOwner(){
        require(msg.sender == owner, "HcSwapV2Router: ONLY_OWNER");
        _;
    }

    modifier onlyOperator(){
        require(isOperator(msg.sender), "HcSwapV2Router: ONLY_OPERATOR");
        _;
    }

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'HcSwapV2Router: EXPIRED');
        _;
    }

    function setOwner(address _owner) onlyOwner public {
        owner = _owner;
    }

    function setFactoryOwner(address _owner) onlyOwner public {
        if(IHcSwapBSCFactory(factory).owner() == address(this)){
            IHcSwapBSCFactory(factory).setOwner(_owner);
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

    function setOperator(address[] memory _ops, bool[] memory _status) onlyOwner public {
        require(_ops.length == _status.length, "HcSwapV2Router:SET_OPERATOR_WRONG_DATA");
        for (uint i = 0; i < _ops.length; i++) {
            operator[_ops[i]] = _status[i];
        }
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
        owner = msg.sender;
        tasks.initStorage();
    }

    receive() external payable {
        require(msg.sender == WETH);
        // only accept ETH via fallback from the WETH contract
    }

    function requireMinAmount(address token, uint amount) public view {
        uint requireMin = minAmount[token] > 0 ? minAmount[token] : 1 finney;
        require(amount >= requireMin, "HcSwap::requireMinAmount NEED_MORE_AMOUNT");
    }

    function setMinAmount(address[] memory _tokens, uint[] memory _amount) onlyOwner public {
        require(_tokens.length == _amount.length, "HcSwapRouter: INVALID_MIN_AMOUNT_DATA");
        for (uint i = 0; i < _tokens.length; i++) {
            minAmount[_tokens[i]] = _amount[i];
        }
    }

    function onCrossSync(CrossAction[] calldata actions) external onlyOperator {
        for (uint256 i = 0; i < actions.length; i++) {
            CrossAction memory action = actions[i];
            IHcSwapBSCPair pair = IHcSwapBSCPair(UniswapV2Library.pairFor(factory, action.tokenA, action.tokenB));

            (address token0,address token1) = (pair.token0(), pair.token1());
            (uint256 amount0,uint256 amount1) = action.tokenA == pair.token0() ? (action.amountA, action.amountB) : (action.amountB, action.amountA);
            if (action.actionType == 0) {//sync
                if (IERC20(token0).balanceOf(address(pair)) < amount0) {
                    TransferHelper.safeTransferFrom(token0, msg.sender, address(pair), amount0.sub(IERC20(token0).balanceOf(address(pair))));
                }
                if (IERC20(token1).balanceOf(address(pair)) < amount1) {
                    TransferHelper.safeTransferFrom(token1, msg.sender, address(pair), amount1.sub(IERC20(token1).balanceOf(address(pair))));
                }
                pair.directlySync(amount0, amount1);
            } else {// mint lp
                LPQueue.LPAction storage task = tasks.readFirst();
                emit CrossTaskDone(tasks.currentIndex(), action.actionType == 1, action.success);
                if (action.actionType == 1) {
                    require(action.checksum == task.checksum, "HcSwap:CHECKSUM_ERROR");
                    (,,uint amountADesired,uint amountBDesired,,,,) = LPQueue.decodeAddLP(task.payload);
                    if (action.success) {
                        require(action.liquidity > 0, "HcSwap:ZERO_LIQUIDITY");
                        TransferHelper.safeTransfer(action.tokenA, address(pair), action.amountA);
                        TransferHelper.safeTransfer(action.tokenB, address(pair), action.amountB);

                        if (amountADesired > action.amountA) {
                            TransferHelper.safeTransfer(action.tokenA, task.to, amountADesired.sub(action.amountA));
                        }
                        if (amountBDesired > action.amountB) {
                            TransferHelper.safeTransfer(action.tokenB, task.to, amountBDesired.sub(action.amountB));
                        }

                        pair.directlyMint(action.liquidity, task.to);
                    } else {
                        TransferHelper.safeTransfer(action.tokenA, task.to, amountADesired);
                        TransferHelper.safeTransfer(action.tokenB, task.to, amountBDesired);
                    }
                    tasks.dequeue();
                } else if (action.actionType == 2) {
                    require(action.checksum == task.checksum, "HcSwap: INVALID_CHECKSUM");
                    //tokenA,tokenB,liquidity,amountAMin,amountBMin,to,deadline
                    (,,uint liquidity,,,,) = LPQueue.decodeRemoveLP(task.payload);
                    require(action.liquidity == liquidity, "HcSwap: INVALID_LIQUIDITY");
                    if (action.success) {
                        pair.directlyBurn(action.liquidity, address(this), task.to, amount0, amount1);
                    } else {
                        TransferHelper.safeTransfer(address(pair), task.to, action.liquidity);
                    }
                    tasks.dequeue();
                } else {
                    revert('HcSwap:UNKNOWN_TYPE');
                }
            }
        }
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
        // create the pair if it doesn't exist yet
        if (IHcSwapBSCFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            require(isOperator(msg.sender), "HcSwapBSC:NOT_OPERATOR");
            IHcSwapBSCPair pair = IHcSwapBSCPair(IHcSwapBSCFactory(factory).createPair(tokenA, tokenB));
            (uint amount0,uint amount1) = pair.token0() == tokenA ? (amountADesired, amountBDesired) : (amountBDesired, amountADesired);
            emit CreateCrossLP(address(pair), pair.token0(), pair.token1(), amount0, amount1);
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

    function addLiquidityFromUser(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        uint deadline
    ) external ensure(deadline) lock whenNotPaused returns (uint256 index) {
        address to = msg.sender;
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        require(pair != address(0), "HcSwapBSC: ONLY_CREATED_LP_ALLOW");
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), amountADesired);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), amountBDesired);
        requireMinAmount(tokenA, amountADesired);
        requireMinAmount(tokenB, amountBDesired);

        LPQueue.LPAction memory lpAction = LPQueue.encodeAddLP(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline);
        tasks.enqueue(lpAction);
        index = tasks.last;
        emit CrossLiquidity(index, lpAction.checksum, true, lpAction);
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
    ) external virtual override ensure(deadline) onlyOperator returns (uint amountA, uint amountB, uint liquidity) {
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
    ) external virtual override payable ensure(deadline) onlyOperator returns (uint amountToken, uint amountETH, uint liquidity) {
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
    ) public virtual override ensure(deadline) onlyOperator returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        // send liquidity to pair
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'HcSwapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'HcSwapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    function removeLiquidityFromUser(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        uint deadline
    ) external ensure(deadline) lock whenNotPaused returns (uint256 index) {
        address to = msg.sender;
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        require(pair != address(0), "HcSwapBSC:ONLY_CREATED_LP");
        IUniswapV2Pair(pair).transferFrom(msg.sender, address(this), liquidity);
        // send liquidity to pair
        requireMinAmount(pair, liquidity);
        LPQueue.LPAction memory lpAction = LPQueue.encodeRemoveLP(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
        tasks.enqueue(lpAction);
        index = tasks.last;
        emit CrossLiquidity(index, lpAction.checksum, false, lpAction);
    }

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) onlyOperator returns (uint amountToken, uint amountETH) {
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
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) onlyOperator returns (uint[] memory amounts) {
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
    ) external virtual override ensure(deadline) onlyOperator returns (uint[] memory amounts) {
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
    onlyOperator
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
    onlyOperator
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
    onlyOperator
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
    onlyOperator
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

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
    public
    pure
    virtual
    override
    returns (uint amountOut)
    {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
    public
    pure
    virtual
    override
    returns (uint amountIn)
    {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
    public
    view
    virtual
    override
    returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
    public
    view
    virtual
    override
    returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}

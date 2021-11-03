pragma solidity =0.6.6;

library LPQueue {
    struct LPAction {
        bool addLP;
        address to;
        bytes32 checksum;
        bytes payload;
    }

    struct Store {
        mapping(uint256 => LPAction) queue;
        uint256 first;
        uint256 last;
        bool init;
    }

    function initStorage(Store storage s) internal {
        s.first = 1;
        s.last = 0;
        s.init = true;
    }

    function currentIndex(Store storage s) internal view returns (uint256) {
        require(s.init == true);
        require(s.last >= s.first, "Queue is Empty");
        return s.first;
    }

    function enqueue(Store storage s, LPAction memory data)
        internal
        returns (LPAction memory)
    {
        require(s.init == true);
        s.last += 1;
        s.queue[s.last] = data;

        return data;
    }

    function encodeAddLP(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) internal pure returns(LPQueue.LPAction memory) {
        bytes memory payload = abi.encode(tokenA,tokenB,amountADesired,amountBDesired,amountAMin,amountBMin,to,deadline);
        bytes32 checksum = keccak256(abi.encode(true, to, payload));
        return LPAction(true,to,checksum,payload);
    }

    //tokenA,tokenB,amountADesired,amountBDesired,amountAMin,amountBMin,to,deadline
    function decodeAddLP(bytes memory payload) internal pure returns(address,address,uint,uint,uint,uint,address,uint){
        return abi.decode(payload,(address,address,uint,uint,uint,uint,address,uint));
    }

    function encodeRemoveLP(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) internal pure returns(LPQueue.LPAction memory) {
        bytes memory payload = abi.encode(tokenA,tokenB,liquidity,amountAMin,amountBMin,to,deadline);
        bytes32 checksum = keccak256(abi.encode(false, to, payload));
        return LPAction(false,to,checksum,payload);
    }

    //tokenA,tokenB,liquidity,amountAMin,amountBMin,to,deadline
    function decodeRemoveLP(bytes memory payload) internal pure returns(address,address,uint,uint,uint,address,uint){
        return abi.decode(payload,(address,address,uint,uint,uint,address,uint));
    }

    function checkData(LPQueue.LPAction memory action) internal pure returns(bool){
        return action.checksum == keccak256(abi.encode(action.addLP, action.to, action.payload));
    }

    function readFirst(Store storage s)
        internal
        view
        returns (LPAction storage data)
    {
        data = s.queue[currentIndex(s)];
    }

    function readFirstPayload(Store storage s) internal view returns(bytes memory payload){
        return s.queue[currentIndex(s)].payload;
    }

    function dequeue(Store storage s) internal {
        require(s.init == true);
        require(s.last >= s.first, "Queue is Empty");
        delete s.queue[s.first];
        s.first += 1;
    }
}

pragma solidity =0.5.16;

import "./HcSwapAvaxERC20.sol";

contract HcToken is HcSwapAvaxERC20 {

    address public originAddress;
    mapping(address => bool) public blackList;
    address public owner;
    mapping(address => bool) public minter;

    event TransferOwnership(address indexed newOwner_);
    event SetBlackList(address indexed addr, bool status);
    event SetMinter(address indexed addr, bool status);

    modifier onlyOwner() {
        require(msg.sender == owner, string(abi.encodePacked("HcToken ", name, ":ONLY_OWNER")));
        _;
    }

    modifier onlyMinter() {
        require(minter[msg.sender] == true, string(abi.encodePacked("HcToken ", name, ":ONLY_MINTER")));
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address originAddress_, address owner_) HcSwapAvaxERC20() public
    {
        name = string(abi.encodePacked("a", name_));
        symbol = string(abi.encodePacked("a", symbol_));
        decimals = decimals_;
        originAddress = originAddress_;
        owner = owner_;
        minter[owner] = true;
    }

    function transferOwnership(address newOwner_) onlyOwner public {
        owner = newOwner_;
        emit TransferOwnership(newOwner_);
    }


    function setBlackList(address[] memory addresses_, bool[] memory status_) onlyOwner public {
        require(addresses_.length == status_.length, "HcToken::setBlackList WRONG_DATA");
        for (uint i = 0; i < addresses_.length; i++) {
            blackList[addresses_[i]] = status_[i];
            emit SetBlackList(addresses_[i], status_[i]);
        }
    }

    function setMinter(address[] memory addresses_, bool[] memory status_) onlyOwner public {
        require(addresses_.length == status_.length, "HcToken::setMinter WRONG_DATA");
        for (uint i = 0; i < addresses_.length; i++) {
            minter[addresses_[i]] = status_[i];
            emit SetMinter(addresses_[i], status_[i]);
        }
    }

    function superMint(address to_, uint256 amount_) onlyMinter public {
        _mint(to_, amount_);
    }

    function superBurn(address account_, uint256 amount_) onlyMinter public {
        _burn(account_, amount_);
    }

    function burn(uint256 amount_) public {
        _burn(msg.sender, amount_);
    }

    function _transfer(address from, address to, uint value) internal {
        require(!blackList[from] && !blackList[to], "HcToken: IN_BLACK_LIST");
        super._transfer(from, to, value);
    }
}

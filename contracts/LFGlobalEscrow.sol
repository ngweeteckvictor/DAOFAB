// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.11;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface for Compound Protocol
interface CEth {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint) external returns (uint256);
}

// Interface for Compound Protocol
interface CErc20 {
    function mint(uint256) external returns (uint256);
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint) external returns (uint256);    
}

contract DFGlobalEscrow is Ownable {
    
    enum Sign {
        NULL,
        REVERT,
        RELEASE
    }
    
    enum TokenType {
        ETH,
        ERC20
    }
    
    // Improvement:
    // Reference: https://docs.soliditylang.org/en/v0.8.11/internals/layout_in_storage.html
    // Multiple, contiguous items that need less than 32 bytes are packed into a single storage slot if possible.
    // Due to their unpredictable size, mappings and dynamically-sized array types cannot be stored “in between” the state variables.
    // struct variables rearranged and packed to save gas
    struct EscrowRecord {
        TokenType tokenType; 
        bool funded;         
        bool disputed;       
        bool finalized;

        // Improvement:
        // Remove as not needed
        //bool shouldInvest;

        address payable delegator;
        address payable owner;
        address payable recipient;
        address payable agent;
        address tokenAddress;

        uint256 fund;
        uint256 releaseCount;
        uint256 revertCount;
        uint256 lastTxBlock;        

        // Improvement: 
        // Sugges to change string to byteX if the referenceId is less than 32 characters
        // or other data type to save gas and then pack with other variables
        string referenceId;     
        mapping(address => bool) signer;
        mapping(address => Sign) signed; 
    }

    mapping(string => EscrowRecord) _escrow;

    // Improvement:
    // Remove functions as not needed
    /*
    function isSigner(
        string memory _referenceId, 
        address _signer
    )
        public
        view
        returns (bool)
    {
        return _escrow[_referenceId].signer[_signer];
    }

    function getSignedAction(
        string memory _referenceId, 
        address _signer
    )
        public
        view
        returns (Sign)
    {
        return _escrow[_referenceId].signed[_signer];
    }
    */

    // Improvement:
    // Emitting events cost gas, use events only when neccessary
    // Remove events that are not neccessary
    event EscrowInitiated(
        string referenceId,
        address payer,
        uint256 amount,
        address payee,
        address trustedParty,
        uint256 lastBlock
    );

    event Signature(
        string referenceId,
        address signer,
        Sign action,
        uint256 lastBlock
    );

    event Finalized(
        string referenceId, 
        address winner, 
        uint256 lastBlock
    );
    
    event Disputed(
        string referenceId, 
        address disputer, 
        uint256 lastBlock
    );
    
    event Withdrawn(
        string referenceId,
        address payee,
        uint256 amount,
        uint256 lastBlock
    );
    
    // Improvement:
    // As indexed parameters cost additional gas, use indexed parameters only if needed.
    event Funded(
        // string indexed referenceId,
        // address indexed owner,
        string referenceId,
        address owner,
        uint256 amount,
        uint256 lastBlock
    );

    // Events for Compound Protocol   
    event FundToCTokens (
        string referenceId,
        uint256 cTokens
    );

    modifier multisigcheck(
        string memory _referenceId, 
        address _party
    ) 
    {
        EscrowRecord storage e = _escrow[_referenceId];
        require(!e.finalized, "Escrow should not be finalized");
        require(e.signer[_party], "party should be eligible to sign");
        require(e.signed[_party] == Sign.NULL, "party should not have signed already");
        _;
        if (e.releaseCount == 2) {
            transferOwnership(e);
        } else if (e.revertCount == 2) {
            finalize(e);
        } else if (e.releaseCount == 1 && e.revertCount == 1) {
            dispute(e, _party);
        }
    }

    modifier onlyEscrowOwner(
        string memory _referenceId
    ) 
    {
        require(_escrow[_referenceId].owner == msg.sender,"Sender must be Escrow's owner");
        _;
    }

    modifier onlyEscrowOwnerOrDelegator(
        string memory _referenceId
    ) 
    {
        require(
            _escrow[_referenceId].owner == msg.sender ||
            _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's owner or delegator"
        );
        _;
    }

    modifier onlyEscrowPartyOrDelegator(
        string memory _referenceId
    ) {
        require(
            _escrow[_referenceId].owner == msg.sender ||
            _escrow[_referenceId].recipient == msg.sender ||
            _escrow[_referenceId].agent == msg.sender ||
            _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's Owner or Recipient or agent or delegator"
        );
        _;
    }

    modifier onlyEscrowOwnerOrRecipientOrDelegator(
        string memory _referenceId
    ) 
    {
        require(
            _escrow[_referenceId].owner == msg.sender ||
            _escrow[_referenceId].recipient == msg.sender ||
            _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's Owner or Recipient or delegator"
        );
        _;
    }

    modifier isFunded(
        string memory _referenceId
    ) 
    {
        require(_escrow[_referenceId].funded == true, "Escrow should be funded");
        _;
    }

    // Improvement:
    // payable modifier not needed as function does not need to receive any Ether
    function createEscrow(
        string memory _referenceId,
        address payable _owner,
        address payable _recipient,
        address payable _agent,
        TokenType tokenType,
        address erc20TokenAddress,
        uint256 tokenAmount
    ) 
        public 
        // payable
        onlyOwner 
    {
        // Improvement:
        // Not needed as impossible to find msg.sender with address(0)
        // require(msg.sender != address(0), "Sender should not be null");

        // Improvement:
        // update error message for readability
        // require(_owner != address(0), "Recipient should not be null");
        
        require(_owner != address(0), "Owner should not be null");
        require(_recipient != address(0), "Recipient should not be null");
        require(_agent != address(0), "Trusted Agent should not be null");
        require(_escrow[_referenceId].lastTxBlock == 0, "Duplicate Escrow");

        EscrowRecord storage e = _escrow[_referenceId];

        e.referenceId = _referenceId;
        e.owner = _owner;

        // Improvement:
        // change comparison operators to perform comparison only once
        // if (!(e.owner == msg.sender)) {
        if (_owner != msg.sender) {
            e.delegator = payable(msg.sender);
        }

        e.recipient = _recipient;
        e.agent = _agent;
        e.tokenType = tokenType;

        // Improvement:
        // read from memory is cheaper than from storage
        // if (e.tokenType == TokenType.ETH) {
        if (tokenType == TokenType.ETH) {
            // Improvement:
            // Suggest the front-end application to set tokenAmount as Wei so to allow funds in smaller denomination.
            e.fund = tokenAmount;   
        } else {
            e.tokenAddress = erc20TokenAddress;
            e.fund = tokenAmount;
        }

        // Improvement:
        // Initialization not needed as default value is false and 0 when declared, save on gas
        /*
        e.funded = false;
        e.disputed = false;
        e.finalized = false;
        e.releaseCount = 0;
        e.revertCount = 0;
        */

        e.lastTxBlock = block.number;

        // Improvement:
        // Use e.signer instead of _escrow[_referenceId] for coding consistency
        /*
        _escrow[_referenceId].signer[_owner] = true;
        _escrow[_referenceId].signer[_recipient] = true;
        _escrow[_referenceId].signer[_agent] = true;
        */
        e.signer[_owner] = true;
        e.signer[_recipient] = true;
        e.signer[_agent] = true;

        // Improvement
        // Use tokenAmount instead of e.fund for coding consistency
        /*
        emit EscrowInitiated(
            _referenceId,
            _owner,
            e.fund,
            _recipient,
            _agent,
            block.number
        );
        */
        emit EscrowInitiated(
            _referenceId,
            _owner,
            tokenAmount,
            _recipient,
            _agent,
            block.number
        );
    }

    // Weakness:
    // Reference: https://consensys.github.io/smart-contract-best-practices/development-recommendations/general/external-calls/
    // Avoid state changes after the call due to reentrancy vulnerabilities
    // Recommend finishing all internal work before calling the external function to avoid reentrancy attacks.
    function fund(
        string memory _referenceId, 
        uint256 fundAmount
    )
        public
        payable
        onlyEscrowOwnerOrDelegator(_referenceId)
    {
        // Improvement:
        // Not needed as modifier onlyEscrowOwnerOrDelegator will revert the function when escrow not create with the referenceId 
        // since escrow owner or delegator, which is address(0), will not be equal to the msg.sender.
        /*
        require(
            _escrow[_referenceId].lastTxBlock > 0,
            "Sender should not be null"
        );
        */

        // Improvement: 
        // New variable is created and cost additional gas, therefore not needed as the value can be reference from storage.
        //uint256 escrowFund = _escrow[_referenceId].fund;

        EscrowRecord storage e = _escrow[_referenceId];

        // Improvement:
        // Moved to avoid reentrancy vulnerabilities
        e.funded = true;
        
        // Improvement:
        // Included to store the last block number
        e.lastTxBlock = block.number;

        // Improvement:
        // Moved to avoid reentrancy vulnerabilities
        // Use e.fund instead of creating new variable escrowFund.
        emit Funded(_referenceId, e.owner, e.fund, block.number);

        if (e.tokenType == TokenType.ETH) {
            require(
                // Error: 
                // Should be "==" to check fund
                // msg.value >= escrowFund,
                
                // Improvement: 
                // msg.value check the amount of Wei sent. If the e.fund is stored in Ether, needs to convert Wei to Ether.
                // Suggest the front-end application to set tokenAmount as Wei so to allow funds in smaller denomination.
                // Use e.fund instead of creating new variable escrowFund.
                 msg.value == e.fund,     
                "Must fund for exact ETH-amount in Escrow"
            );
        } else {
            require(
                // Improvement:
                // Use e.fund instead of creating new variable escrowFund.
                //fundAmount == escrowFund,
                fundAmount == e.fund,
                "Must fund for exact ERC20-amount in Escrow"
            );
            IERC20 erc20Instance = IERC20(e.tokenAddress);
            erc20Instance.transferFrom(msg.sender, address(this), fundAmount);
        }

        // Weakness:
        // state changes after external call transferFrom(), reentrancy vulnerabilities
        // code moved to before external call 
        //e.funded = true;

        // Weakness:
        // state changes after external call transferFrom(), reentrancy vulnerabilities
        // code moved to before external call 
        //emit Funded(_referenceId, e.owner, escrowFund, block.number);
    }
    
    function release(
        string memory _referenceId, 
        address _party
    )
        public
        multisigcheck(_referenceId, _party)
        onlyEscrowPartyOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];
        
        //Improvement:
        // require() in the function are not needed as modifier multisigcheck 
        // already check that _party should be owner, receipient or agent.
        /*
        require(
            _party == e.owner || _party == e.recipient || _party == e.agent,
            "Only owner or recipient or agent can reverse an escrow"
        );
        */

        // Improvement:
        // Place emit at the end of function to notify the completion of the function
        // emit Signature(_referenceId, e.owner, Sign.RELEASE, e.lastTxBlock);
        // e.signed[e.owner] = Sign.RELEASE;

        e.releaseCount++;

        // Improvement:
        // Added code to update the last transaction block number
        e.lastTxBlock = block.number;

        // Improvement:
        // If msg.sender is not delegator, change the function to use msg.sender to agree release the funds 
        // instead of user-specified _party address to prevent the sender/receipient to fake as other party
        // to release the fund.
        if(e.delegator != msg.sender) {
            e.signed[msg.sender] = Sign.RELEASE;
            emit Signature(_referenceId, msg.sender, Sign.RELEASE, e.lastTxBlock);
        }
        else {
            e.signed[_party] = Sign.RELEASE;
            emit Signature(_referenceId, _party, Sign.RELEASE, e.lastTxBlock);
        }
    }
        
    // Improvement:
    // change the order of the modifier
    function reverse(
        string memory _referenceId, 
        address _party
    )
        public
        multisigcheck(_referenceId, _party)
        onlyEscrowPartyOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];

        //Improvement:
        // require() in the function are not needed as modifier multisigcheck 
        // already check that _party should be owner, receipient or agent.
        /*
        require(
            _party == e.owner || _party == e.recipient || _party == e.agent,
            "Only owner or recipient or agent can reverse an escrow"
        );
        */

        // Improvement:
        // Place emit at the end of function to notify the completion of the function
        // emit Signature(_referenceId, e.owner, Sign.REVERT, e.lastTxBlock);
        // e.signed[e.owner] = Sign.REVERT;
        
        e.revertCount++;

        // Improvement:
        // Added code to update the last transaction block number
        e.lastTxBlock = block.number;

        // Improvement:
        // If msg.sender is not delegator, change the function to use msg.sender to agree revert the funds 
        // instead of user-specified _party address to prevent the sender/receipient to fake as other party
        // to revert the fund.
        if(e.delegator != msg.sender) {
            e.signed[msg.sender] = Sign.REVERT;
            emit Signature(_referenceId, msg.sender, Sign.REVERT, e.lastTxBlock);
        }
        else {
            e.signed[_party] = Sign.REVERT;
            emit Signature(_referenceId, _party, Sign.REVERT, e.lastTxBlock);
        }
    }
    
    function dispute(
        string memory _referenceId, 
        address _party
    )
        public
        onlyEscrowOwnerOrRecipientOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];
        require(!e.finalized, "Cannot dispute on a finalised Escrow");
        require(
            _party == e.owner || _party == e.recipient,
            "Only owner or recipient can dispute on escrow"
        );
        dispute(e, _party);
    }
    
    function transferOwnership(
        EscrowRecord storage e
    ) 
        internal 
    {
        e.owner = e.recipient;
        finalize(e);
        // Improvement:
        // Not needed since function call is within the same transaction
        // e.lastTxBlock = block.number;
    }

    function dispute(
        EscrowRecord storage e, 
        address _party
    ) 
        internal 
    {
        // Improvement:
        // Place emit at the end of function to notify the completion of the function
        // emit Disputed(e.referenceId, _party, e.lastTxBlock);
        e.disputed = true;
        e.lastTxBlock = block.number;
        emit Disputed(e.referenceId, _party, e.lastTxBlock);
    }

    function finalize(
        EscrowRecord storage e
    ) 
        internal 
    {
        require(!e.finalized, "Escrow should not be finalized");
        // Improvement:
        // Place emit at the end of function to notify the completion of the function
        // emit Finalized(e.referenceId, e.owner, e.lastTxBlock);
        e.finalized = true;
        emit Finalized(e.referenceId, e.owner, e.lastTxBlock);
    }
 
    function withdraw(
        string memory _referenceId, 
        uint256 _amount
        )
        public
        onlyEscrowOwner(_referenceId) 
        isFunded(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];

        require(e.finalized, "Escrow should be finalized before withdrawal");
        require(_amount <= e.fund, "cannot withdraw more than the deposit");

        //Improvement:
        // New variable escrowOwner is created and cost additional gas, therefore not needed 
        // as the value can be reference from storage.
        // address escrowOwner = e.owner;
       
        e.fund = e.fund - _amount;
        e.lastTxBlock = block.number;
        
        emit Withdrawn(_referenceId, e.owner, _amount, block.number);

        if (e.tokenType == TokenType.ETH) {
            // Weakness:
            // Reference: https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/
            // Recommend to stop using transfer() and send() and instead use call()
            // require((e.owner).send(_amount));
            
            (bool success, ) = (e.owner).call{value: _amount}("");
            require(success);
        } else {
            IERC20 erc20Instance = IERC20(e.tokenAddress);
            //require(erc20Instance.transfer(escrowOwner, _amount));
            require(erc20Instance.transfer(e.owner, _amount));
        }
    }

    // Additional Functions for Compound

    // Mint cETH by sending ETH
    function supplyEthToCompound (
        address payable _cEtherContract
    )
        public
        payable
        returns (bool _success)
    {
         // Create a reference to the corresponding cToken contract
        CEth cToken = CEth(_cEtherContract);

        _success = true;

        // Mint cETH, reverts on error
        cToken.mint{ value: msg.value }();
    }

    // Mint cERC20 by sending ERC20 token
    function supplyErc20ToCompound(
        address _erc20Contract,
        address _cErc20Contract,
        uint256 _numTokensToSupply
    ) 
        public 
        returns (uint256 _mintResult)
    {
        // Create a reference to the underlying asset contract, like DAI.
        IERC20 underlying = IERC20(_erc20Contract);

        // Create a reference to the corresponding cToken contract, like cDAI
        CErc20 cToken = CErc20(_cErc20Contract);

        // Approve transfer on the ERC20 contract
        underlying.approve(_cErc20Contract, _numTokensToSupply);

        // Mint cERC20, return 0 on success, otherwise an Error code
        _mintResult = cToken.mint(_numTokensToSupply);
    }

    // Redeem ETH by exchanging cETH
    function redeemCEth(
        uint256 _amount,
        bool _redeemType,
        address _cEtherContract
    ) 
        public
        returns (uint256 _redeemResult)
    {
        // Create a reference to the corresponding cToken contract
        CEth cToken = CEth(_cEtherContract);

        if (_redeemType == true) {
            // Retrieve your asset based on a cToken amount
            _redeemResult = cToken.redeem(_amount);
        } else {
            // Retrieve your asset based on an amount of the asset
            _redeemResult = cToken.redeemUnderlying(_amount);
        }
    }
    
    // This is needed to receive ETH when calling `redeemCEth`
    receive() external payable {}

    // Redeem ERC20 token by exchanging cERC20
    function redeemCErc20Tokens(
        uint256 _amount,
        bool _redeemType,
        address _cErc20Contract
    ) 
        public
        returns (uint256 _redeemResult)
        
    {
        // Create a reference to the corresponding cToken contract, like cDAI
        CErc20 cToken = CErc20(_cErc20Contract);

        if (_redeemType == true) {
            // Retrieve your asset based on a cToken amount
            _redeemResult = cToken.redeem(_amount);
        } else {
            // Retrieve your asset based on an amount of the asset
            _redeemResult = cToken.redeemUnderlying(_amount);
        }
    }
}
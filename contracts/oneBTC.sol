// SPDX-License-Identifier: MIT License
pragma solidity ^0.6.0;

import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IUniswapOracle {
    // We need the current prices of just about everything for the system to work!
    // 
    // Return the average time weighted price of oneBTC (the Bitcoin stable coin),
    // the collateral (USDC, DAI, etc), and the cryptocurrencies (BTC, BTC, etc).
    // This includes functions for changing the time interval for average,
    // updating the oracle price, and returning the current price.
    function changeInterval(uint256 seconds_) external;
    function update() external;
    function consult(address token, uint amountIn) external view returns (uint amountOut);
}

contract oneBTC is ERC20("oneBTC", "oneBTC"), Ownable, ReentrancyGuard {
    // oneBTC is the first fractionally backed stable coin that is especially designed for
    // the Ethereum community.  In its fractional phase, BTC will be paid into the contract
    // to mint new oneBTC.  The Ethereum community will govern this BTC treasury, spending it
    // on public goods, to re-collateralize oneBTC, or on discount and perks for consumers to
    // adopt oneBTC or BTC.
    //
    // This contract is ownable and the owner has tremendous power.  This ownership will be
    // transferred to a multi-sig contract controlled by signers elected by the community.
    //
    // Thanks for reading the contract and happy farming!
    using SafeMath for uint256;

    // At 100% reserve ratio, each oneBTC is backed 1-to-1 by $1 of existing stable coins
    uint256 constant public MAX_RESERVE_RATIO = 100 * 10 ** 9;
    uint256 private constant DECIMALS = 9;
    uint256 public lastRefreshReserve; // The last time the reserve ratio was updated by the contract
    uint256 public minimumRefreshTime; // The time between reserve ratio refreshes

    address public stimulus; // oneBTC builds a stimulus fund in BTC.
    uint256 public stimulusDecimals; // used to calculate oracle rate of Uniswap Pair

    // We get the price of BTC from Chainlink!  Thanks chainLink!  Hopefully, the chainLink
    // will provide Oracle prices for oneBTC, oneBTC, etc in the future.  For now, we will get those
    // from the ichi.farm exchange which uses Uniswap contracts.
    AggregatorV3Interface internal chainlinkStimulusOracle;
    AggregatorV3Interface internal ethPrice;


    address public oneTokenOracle; // oracle for the oneBTC stable coin
    address public stimulusOracle;  // oracle for a stimulus cryptocurrency that isn't on chainLink
    bool public chainLink;         // true means it is a chainLink oracle

    // Only governance should cause the coin to go fully agorithmic by changing the minimum reserve
    // ratio.  For now, we will set a conservative minimum reserve ratio.
    uint256 public MIN_RESERVE_RATIO;
    uint256 public MIN_DELAY;

    // Makes sure that you can't send coins to a 0 address and prevents coins from being sent to the
    // contract address. I want to protect your funds! 
    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    uint256 private _totalSupply;
    mapping(address => uint256) private _oneBalances;
    mapping(address => uint256) private _lastCall;
    mapping (address => mapping (address => uint256)) private _allowedOne;

    address public wethAddress;
    address public ethUsdcUniswapOracle;
    address public gov;
    // allows you to transfer the governance to a different user - they must accept it!
    address public pendingGov;
    uint256 public reserveStepSize; // step size of update of reserve rate (e.g. 5 * 10 ** 8 = 0.5%)
    uint256 public reserveRatio;    // a number between 0 and 100 * 10 ** 9.
                                    // 0 = 0%
                                    // 100 * 10 ** 9 = 100%

    // map of acceptable collaterals
    mapping (address => bool) public acceptedCollateral;
    address[] public collateralArray;

    // modifier to allow auto update of TWAP oracle prices
    // also updates reserves rate programatically
    modifier updateProtocol() {
        if (address(oneTokenOracle) != address(0)) {
            // only update if stimulusOracle is set
            if (!chainLink) IUniswapOracle(stimulusOracle).update();

            // this is always updated because we always need stablecoin oracle price
            IUniswapOracle(oneTokenOracle).update();

            for (uint i = 0; i < collateralArray.length; i++){ 
                if (acceptedCollateral[collateralArray[i]]) IUniswapOracle(collateralOracle[collateralArray[i]]).update();
            }

            // update reserve ratio if enough time has passed
            if (block.timestamp - lastRefreshReserve >= minimumRefreshTime) {
                // $Z / 1 one token
                if (getOneTokenUsd() > 1 * 10 ** 9) {
                    setReserveRatio(reserveRatio.sub(reserveStepSize));
                } else {
                    setReserveRatio(reserveRatio.add(reserveStepSize));
                }

                lastRefreshReserve = block.timestamp;
            }
        }
        
        _;
    }

    event NewPendingGov(address oldPendingGov, address newPendingGov);
    event NewGov(address oldGov, address newGov);
    event NewReserveRate(uint256 reserveRatio);
    event Mint(address stimulus, address receiver, address collateral, uint256 collateralAmount, uint256 stimulusAmount, uint256 oneAmount);
    event Withdraw(address stimulus, address receiver, address collateral, uint256 collateralAmount, uint256 stimulusAmount, uint256 oneAmount);
    event NewMinimumRefreshTime(uint256 minimumRefreshTime);

    modifier onlyIchiGov() {
        require(msg.sender == gov, "ACCESS: only Ichi governance");
        _;
    }

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    mapping (address => uint256) public collateralDecimals;
    mapping (address => bool) public previouslySeenCollateral;
    mapping (address => address) public collateralOracle;       // address of the Collateral-BTC Uniswap Price

    // default to 0
    uint256 public mintFee;
    uint256 public withdrawFee;
    uint256 public minBlockFreeze;

    // fee to charge when minting oneBTC - this will go into collateral
    event MintFee(uint256 fee_);
    // fee to charge when redeeming oneBTC - this will go into collateral
    event WithdrawFee(uint256 fee_);

    // set governance access to only oneBTC - BTC pool multisig (elected after rewards)
    modifier btcLPGov() {
        require(msg.sender == lpGov, "ACCESS: only btcLP governance");
        _;
    }

    address public lpGov;
    address public pendingLPGov;

    event NewPendingLPGov(address oldPendingLPGov, address newPendingLPGov);
    event NewLPGov(address oldLPGov, address newLPGov);

    mapping (address => uint256) private _burnedStablecoin; // maps user to burned oneBTC

    // important: make sure changeInterval is a function to allow the interval of update to change
    function addCollateral(address collateral_, uint256 collateralDecimal_, address oracleAddress_)
        external
        btcLPGov
    {
        // only add collateral once
        if (!previouslySeenCollateral[collateral_]) collateralArray.push(collateral_);

        previouslySeenCollateral[collateral_] = true;
        acceptedCollateral[collateral_] = true;
        collateralDecimals[collateral_] = collateralDecimal_;
        collateralOracle[collateral_] = oracleAddress_;
    }

    function setReserveStepSize(uint256 stepSize_)
        external
        btcLPGov
    {
        reserveStepSize = stepSize_;
    }

    function setCollateralOracle(address collateral_, address oracleAddress_)
        external
        btcLPGov
    {
        require(acceptedCollateral[collateral_], "invalid collateral");
        collateralOracle[collateral_] = oracleAddress_;
    }

    function removeCollateral(address collateral_)
        external
        btcLPGov
    {
        acceptedCollateral[collateral_] = false;
    }

    // used for querying
    function getBurnedStablecoin(address _user)
        public
        view
        returns (uint256)
    {
        return _burnedStablecoin[_user];
    }

    // returns 10 ** 9 price of collateral
    function getCollateralUsd(address collateral_) public view returns (uint256) {
        require(previouslySeenCollateral[collateral_], "must be an existing collateral");
        uint256 ethUsdcTWAP = IUniswapOracle(ethUsdcUniswapOracle).consult(wethAddress, 1 * 10 ** 18);  // 1 ETH = X USDC (10 ^ 6 decimals)
        return ethUsdcTWAP.mul(10 ** 3).mul(10 ** 9).div((IUniswapOracle(collateralOracle[collateral_]).consult(wethAddress, 10 ** 18)).mul(10 ** 9).div(10 ** collateralDecimals[collateral_]));
    }

    function globalCollateralValue() public view returns (uint256) {
        uint256 totalCollateralUsd = 0; 

        for (uint i = 0; i < collateralArray.length; i++){ 
            // Exclude null addresses
            if (collateralArray[i] != address(0)){
                totalCollateralUsd += IERC20(collateralArray[i]).balanceOf(address(this)).mul(10 ** 9).div(10 ** collateralDecimals[collateralArray[i]]).mul(getCollateralUsd(collateralArray[i])).div(10 ** 9); // add stablecoin balance
            }

        }
        return totalCollateralUsd;
    }

    // return price of oneBTC in 10 ** 9 decimal
    function getOneTokenUsd()
        public
        view
        returns (uint256)
    {
        uint256 oneTokenPrice = IUniswapOracle(oneTokenOracle).consult(stimulus, 10 ** stimulusDecimals); // X one tokens (10 ** 9) / 1 stimulus token
        uint256 stimulusTWAP = getStimulusOracle(); // $Y / 1 stimulus (10 ** 9)

        uint256 oneTokenUsd = stimulusTWAP.mul(10 ** 9).div(oneTokenPrice); // 10 ** 9 decimals
        return oneTokenUsd;
    }

    /**
     * @return The total number of oneBTC.
     */
    function totalSupply()
        public
        override
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    /**
     * @param who The address to query.
     * @return The balance of the specified address.
     */
    function balanceOf(address who)
        public
        override
        view
        returns (uint256)
    {
        return _oneBalances[who];
    }

    // oracle asset for collateral (oneBTC is BTC, oneWHBAR is WHBAR, etc...)
    function setChainLinkStimulusOracle(address oracle_)
        external
        btcLPGov
        returns (bool)
    {
        chainlinkStimulusOracle = AggregatorV3Interface(oracle_);
        chainLink = true;

        return true;
    }

    /**
     * @dev Transfer tokens to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transfer(address to, uint256 value)
        public
        override
        validRecipient(to)
        updateProtocol()
        returns (bool)
    {
        _oneBalances[msg.sender] = _oneBalances[msg.sender].sub(value);
        _oneBalances[to] = _oneBalances[to].add(value);
        emit Transfer(msg.sender, to, value);

        return true;
    }

    /**
     * @dev Function to check the amount of tokens that an owner has allowed to a spender.
     * @param owner_ The address which owns the funds.
     * @param spender The address which will spend the funds.
     * @return The number of tokens still available for the spender.
     */
    function allowance(address owner_, address spender)
        public
        override
        view
        returns (uint256)
    {
        return _allowedOne[owner_][spender];
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     * @param value The amount of tokens to be transferred.
     */
    function transferFrom(address from, address to, uint256 value)
        public
        override
        validRecipient(to)
        updateProtocol()
        returns (bool)
    {
        _allowedOne[from][msg.sender] = _allowedOne[from][msg.sender].sub(value);

        _oneBalances[from] = _oneBalances[from].sub(value);
        _oneBalances[to] = _oneBalances[to].add(value);
        emit Transfer(from, to, value);

        return true;
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of
     * msg.sender. This method is included for ERC20 compatibility.
     * increaseAllowance and decreaseAllowance should be used instead.
     * Changing an allowance with this method brings the risk that someone may transfer both
     * the old and the new allowance - if they are both greater than zero - if a transfer
     * transaction is mined before the later approve() call is mined.
     *
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     */
    function approve(address spender, uint256 value)
        public
        override
        validRecipient(spender)
        updateProtocol()
        returns (bool)
    {
        _allowedOne[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to a spender.
     * This method should be used instead of approve() to avoid the double approval vulnerability
     * described above.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        override
        returns (bool)
    {
        _allowedOne[msg.sender][spender] = _allowedOne[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedOne[msg.sender][spender]);
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        override
        returns (bool)
    {
        uint256 oldValue = _allowedOne[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedOne[msg.sender][spender] = 0;
        } else {
            _allowedOne[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedOne[msg.sender][spender]);
        return true;
    }

    function setOneOracle(address oracle_)
        external
        btcLPGov
        returns (bool) 
    {
        oneTokenOracle = oracle_;
        
        return true;
    }

    function setEthUsdcUniswapOracle(address oracle_)
        external
        btcLPGov
        returns (bool)
    {
        ethUsdcUniswapOracle = oracle_;

        return true;
    }

    function setStimulusUniswapOracle(address oracle_)
        external
        btcLPGov
        returns (bool)
    {
        stimulusOracle = oracle_;
        chainLink = false;

        return true;
    }

    // oracle rate is 10 ** 9 decimals
    // returns $Z / Stimulus
    function getStimulusOracle()
        public
        view
        returns (uint256)
    {
        if (chainLink) {
            (
                uint80 roundID, 
                int price,
                uint startedAt,
                uint timeStamp,
                uint80 answeredInRound
            ) = chainlinkStimulusOracle.latestRoundData();

            require(timeStamp > 0, "Rounds not complete");

            return uint256(price).mul(10); // 10 ** 9 price
        } else {
            // stimulusTWAP has `stimulusDecimals` decimals
            uint256 stimulusTWAP = IUniswapOracle(stimulusOracle).consult(wethAddress, 1 * 10 ** 18);       // 1 ETH = X Stimulus, or X Stimulus / ETH
            uint256 ethUsdcTWAP = IUniswapOracle(ethUsdcUniswapOracle).consult(wethAddress, 1 * 10 ** 18);  // 1 ETH = X USDC

            // X USDC / 1 ETH * (1 ETH / x Stimulus) = Y USDC / Stimulus
            return ethUsdcTWAP.mul(10 ** 3).mul(10 ** stimulusDecimals).div(stimulusTWAP); // 10 ** 9 price
        }
    }

    // minimum amount of block time (seconds) required for an update in reserve ratio
    function setMinimumRefreshTime(uint256 val_)
        external
        btcLPGov
        returns (bool)
    {
        require(val_ != 0, "minimum refresh time must be valid");

        minimumRefreshTime = val_;

        // change collateral array
        for (uint i = 0; i < collateralArray.length; i++){ 
            if (acceptedCollateral[collateralArray[i]]) IUniswapOracle(collateralOracle[collateralArray[i]]).changeInterval(val_);
        }

        IUniswapOracle(ethUsdcUniswapOracle).changeInterval(val_);
        // stimulus and oneToken oracle update
        IUniswapOracle(oneTokenOracle).changeInterval(val_);
        if (!chainLink) IUniswapOracle(stimulusOracle).changeInterval(val_);

        // change all the oracles (collateral, stimulus, oneToken)

        emit NewMinimumRefreshTime(val_);
        return true;
    }

    // tokenSymbol: oneBTC etc...
    // stimulus_: address of the stimulus (BTC, wBTC, wHBAR)...
    // stimulusDecimals_: decimals of stimulus (e.g. 18)
    // wethAddress_: address of WETH
    // ethOracleChainLink_: address of chainlink oracle for BTC / USD

    // don't forget to set oracle for stimulus later (BTC, wBTC etc probably can use Chainlink, others use Uniswap)
    // chain link stimulus:     setChainLinkStimulusOracle(address)
    // uniswap stimulus:        setStimulusUniswapOracle(address)  
    constructor(
        uint256 reserveRatio_,
        address stimulus_,
        uint256 stimulusDecimals_,
        address wethAddress_,
        address ethOracleChainLink_,
        address ethUsdcUniswap_,
        uint256 minBlockFreeze_
    )
        public
    {   
        _setupDecimals(uint8(9));
        stimulus = stimulus_;
        minimumRefreshTime = 3600 * 1; // 1 hour by default
        stimulusDecimals = stimulusDecimals_;
        minBlockFreeze = block.number.add(minBlockFreeze_);
        reserveStepSize = 1 * 10 ** 8;  // 0.1% by default
        ethPrice = AggregatorV3Interface(ethOracleChainLink_);
        ethUsdcUniswapOracle = ethUsdcUniswap_;
        MIN_RESERVE_RATIO = 90 * 10 ** 9;
        wethAddress = wethAddress_;
        MIN_DELAY = 3;             // 3 blocks
        withdrawFee = 1 * 10 ** 8; // 0.1% fee at first, remains in collateral
        gov = msg.sender;
        lpGov = msg.sender;
        reserveRatio = reserveRatio_;
        _totalSupply = 10 ** 9;

        _oneBalances[msg.sender] = 10 ** 9;
        emit Transfer(address(0x0), msg.sender, 10 ** 9);
    }
    
    function setMinimumReserveRatio(uint256 val_)
        external
        btcLPGov
    {
        MIN_RESERVE_RATIO = val_;
    }

    function setMinimumDelay(uint256 val_)
        external
        btcLPGov
    {
        MIN_DELAY = val_;
    }

    // LP pool governance ====================================
    function setPendingLPGov(address pendingLPGov_)
        external
        btcLPGov
    {
        address oldPendingLPGov = pendingLPGov;
        pendingLPGov = pendingLPGov_;
        emit NewPendingLPGov(oldPendingLPGov, pendingLPGov_);
    }

    function acceptLPGov()
        external
    {
        require(msg.sender == pendingLPGov, "!pending");
        address oldLPGov = lpGov; // that
        lpGov = pendingLPGov;
        pendingLPGov = address(0);
        emit NewGov(oldLPGov, lpGov);
    }

    // over-arching protocol level governance  ===============
    function setPendingGov(address pendingGov_)
        external
        onlyIchiGov
    {
        address oldPendingGov = pendingGov;
        pendingGov = pendingGov_;
        emit NewPendingGov(oldPendingGov, pendingGov_);
    }

    function acceptGov()
        external
    {
        require(msg.sender == pendingGov, "!pending");
        address oldGov = gov;
        gov = pendingGov;
        pendingGov = address(0);
        emit NewGov(oldGov, gov);
    }
    // ======================================================

    // calculates how much you will need to send in order to mint oneBTC, depending on current market prices + reserve ratio
    // oneAmount: the amount of oneBTC you want to mint
    // collateral: the collateral you want to use to pay
    // also works in the reverse direction, i.e. how much collateral + stimulus to receive when you burn One
    function consultOneDeposit(uint256 oneAmount, address collateral)
        public
        view
        returns (uint256, uint256)
    {
        require(oneAmount != 0, "must use valid oneAmount");
        require(acceptedCollateral[collateral], "must be an accepted collateral");

        // convert to correct decimals for collateral
        uint256 collateralAmount = oneAmount.mul(reserveRatio).div(MAX_RESERVE_RATIO).mul(10 ** collateralDecimals[collateral]).div(10 ** DECIMALS);
        collateralAmount = collateralAmount.mul(10 ** 9).div(getCollateralUsd(collateral));

        if (address(oneTokenOracle) == address(0)) return (collateralAmount, 0);

        uint256 stimulusUsd = getStimulusOracle();     // 10 ** 9

        uint256 stimulusAmountInOneStablecoin = oneAmount.mul(MAX_RESERVE_RATIO.sub(reserveRatio)).div(MAX_RESERVE_RATIO);

        uint256 stimulusAmount = stimulusAmountInOneStablecoin.mul(10 ** 9).div(stimulusUsd).mul(10 ** stimulusDecimals).div(10 ** DECIMALS); // must be 10 ** stimulusDecimals

        return (collateralAmount, stimulusAmount);
    }

    function consultOneWithdraw(uint256 oneAmount, address collateral)
        public
        view
        returns (uint256, uint256)
    {
        require(oneAmount != 0, "must use valid oneAmount");
        require(acceptedCollateral[collateral], "must be an accepted collateral");

        uint256 collateralAmount = oneAmount.sub(oneAmount.mul(withdrawFee).div(100 * 10 ** DECIMALS)).mul(10 ** collateralDecimals[collateral]).div(10 ** DECIMALS);
        collateralAmount = collateralAmount.mul(10 ** 9).div(getCollateralUsd(collateral));

        return (collateralAmount, 0);
    }

    // @title: deposit collateral + stimulus token
    // collateral: address of the collateral to deposit (USDC, DAI, TUSD, etc)
    function mint(
        uint256 oneAmount,
        address collateral
    )
        public
        payable
        nonReentrant
    {
        require(acceptedCollateral[collateral], "must be an accepted collateral");
        require(oneAmount != 0, "must mint non-zero amount");

        // wait 3 blocks to avoid flash loans
        require((_lastCall[msg.sender] + MIN_DELAY) <= block.number, "action too soon - please wait a few more blocks");

        // validate input amounts are correct
        (uint256 collateralAmount, uint256 stimulusAmount) = consultOneDeposit(oneAmount, collateral);
        require(collateralAmount <= IERC20(collateral).balanceOf(msg.sender), "sender has insufficient collateral balance");
        require(stimulusAmount <= IERC20(stimulus).balanceOf(msg.sender), "sender has insufficient stimulus balance");

        // checks passed, so transfer tokens
        SafeERC20.safeTransferFrom(IERC20(collateral), msg.sender, address(this), collateralAmount);
        SafeERC20.safeTransferFrom(IERC20(stimulus), msg.sender, address(this), stimulusAmount);

        // apply mint fee
        oneAmount = oneAmount.sub(oneAmount.mul(mintFee).div(100 * 10 ** DECIMALS));

        _totalSupply = _totalSupply.add(oneAmount);
        _oneBalances[msg.sender] = _oneBalances[msg.sender].add(oneAmount);

        emit Transfer(address(0x0), msg.sender, oneAmount);

        _lastCall[msg.sender] = block.number;

        emit Mint(stimulus, msg.sender, collateral, collateralAmount, stimulusAmount, oneAmount);
    }

    // fee_ should be 10 ** 9 decimals (e.g. 10% = 10 * 10 ** 9)
    function editMintFee(uint256 fee_)
        external
        onlyIchiGov
    {
        mintFee = fee_;
        emit MintFee(fee_);
    }

    // fee_ should be 10 ** 9 decimals (e.g. 10% = 10 * 10 ** 9)
    function editWithdrawFee(uint256 fee_)
        external
        onlyIchiGov
    {
        withdrawFee = fee_;
        emit WithdrawFee(fee_);
    }

    // @title: burn oneBTC and receive collateral + stimulus token
    // oneAmount: amount of oneToken to burn to withdraw
    function withdraw(
        uint256 oneAmount,
        address collateral
    )
        public
        nonReentrant
        updateProtocol()
    {
        require(oneAmount != 0, "must withdraw non-zero amount");
        require(oneAmount <= _oneBalances[msg.sender], "insufficient balance");
        require(previouslySeenCollateral[collateral], "must be an existing collateral");
        require((_lastCall[msg.sender] + MIN_DELAY) <= block.number, "action too soon - please wait a few blocks");

        // burn oneAmount
        _totalSupply = _totalSupply.sub(oneAmount);
        _oneBalances[msg.sender] = _oneBalances[msg.sender].sub(oneAmount);

        _burnedStablecoin[msg.sender] = _burnedStablecoin[msg.sender].add(oneAmount);

        _lastCall[msg.sender] = block.number;
        emit Transfer(msg.sender, address(0x0), oneAmount);
    }

    function withdrawFinal(address collateral)
        public
        nonReentrant
        updateProtocol()
    {
        require(previouslySeenCollateral[collateral], "must be an existing collateral");
        require((_lastCall[msg.sender] + MIN_DELAY) <= block.number, "action too soon - please wait a few blocks");

        uint256 oneAmount = _burnedStablecoin[msg.sender];
        require(oneAmount != 0, "insufficient oneBTC to redeem");

        _burnedStablecoin[msg.sender] = 0;

        // send collateral - fee (convert to collateral decimals too)
        uint256 collateralAmount = oneAmount.sub(oneAmount.mul(withdrawFee).div(100 * 10 ** DECIMALS)).mul(10 ** collateralDecimals[collateral]).div(10 ** DECIMALS);
        collateralAmount = collateralAmount.mul(10 ** 9).div(getCollateralUsd(collateral));

        uint256 stimulusAmount = 0;

        // check enough reserves - don't want to burn one coin if we cannot fulfill withdrawal
        require(collateralAmount <= IERC20(collateral).balanceOf(address(this)), "insufficient collateral reserves - try another collateral");

        SafeERC20.safeTransfer(IERC20(collateral), msg.sender, collateralAmount);

        _lastCall[msg.sender] = block.number;

        emit Withdraw(stimulus, msg.sender, collateral, collateralAmount, stimulusAmount, oneAmount);
    }

    // change reserveRatio
    // market driven -> decide the ratio automatically
    // if one coin >= $1, we lower reserve rate by half a percent
    // if one coin < $1, we increase reserve rate
    function setReserveRatio(uint256 newRatio_)
        internal
    {
        require(newRatio_ >= 0, "positive reserve ratio");

        if (newRatio_ <= MAX_RESERVE_RATIO && newRatio_ >= MIN_RESERVE_RATIO) {
            reserveRatio = newRatio_;
            emit NewReserveRate(reserveRatio);
        }
    }

    // in case any eth get sent
    function safeTransferETH(address to, uint value) 
        public
        btcLPGov
    {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    /// @notice Move stimulus - multisig only
    function moveStimulus(
        address location,
        uint256 amount
    )
        public
        btcLPGov
    {
        require(block.number > minBlockFreeze, "minBlockFreeze time limit not met yet - try again later");
        SafeERC20.safeTransfer(IERC20(stimulus), location, amount);
    }

}
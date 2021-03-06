// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./DigitalaxAccessControls.sol";
import "./garment/IDigitalaxGarmentNFT.sol";
import "./garment/DigitalaxGarmentCollectionV2.sol";
import "./EIP2771/BaseRelayRecipient.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "./oracle/IDripOracle.sol";

/**
 * @notice Marketplace contract for Digitalax NFTs
 */
contract DripMarketplace is ReentrancyGuard, BaseRelayRecipient, Initializable {
    using SafeMath for uint256;
    using Address for address payable;
    /// @notice Event emitted only on construction. To be used by indexers
    event DigitalaxMarketplaceContractDeployed();
    event CollectionPauseToggled(
        uint256 indexed garmentCollectionId,
        bool isPaused
    );
    event PauseToggled(
        bool isPaused
    );
    event FreezeERC20PaymentToggled(
        bool freezeERC20Payment
    );
    event OfferCreated(
        uint256 indexed garmentCollectionId,
        uint256 primarySalePrice,
        uint256 startTime,
        uint256 endTime,
        uint256 discountToPayERC20,
        uint256 maxAmount
    );
    event UpdateAccessControls(
        address indexed accessControls
    );
    event UpdateMarketplaceDiscountToPayInErc20(
        uint256 indexed garmentCollectionId,
        uint256 discount
    );
    event UpdateOfferPrimarySalePrice(
        uint256 indexed garmentCollectionId,
        uint256 primarySalePrice
    );
    event UpdateOfferMaxAmount(
        uint256 indexed garmentCollectionId,
        uint256 maxAmount
    );
    event UpdateOfferCustomPaymentToken(
        uint256 indexed garmentCollectionId,
        address customPaymentToken
    );
    event UpdateOfferStartEnd(
        uint256 indexed garmentCollectionId,
        uint256 startTime,
        uint256 endTime
    );
    event UpdateOracle(
        address indexed oracle
    );
    event UpdatePlatformFeeRecipient(
        address payable platformFeeRecipient
    );

    event OfferPurchased(
        uint256 bundleTokenId,
        uint256 garmentCollectionId,
        uint256 shippingAmount,
        uint256 tokenTransferredAmount,
        uint256 offerId
    );

    event OfferCancelled(
        uint256 indexed bundleTokenId
    );

    event UpdateOfferAvailableIndex(
        uint256 indexed garmentCollectionId,
        uint256 availableIndex
    );
    /// @notice Parameters of a marketplace offer
    struct Offer {
        uint256 primarySalePrice;
        uint256 startTime;
        uint256 endTime;
        uint256 availableIndex;
        uint256 discountToPayERC20;
        uint256 maxAmount;
        bool paused;
    }

    /// @notice Garment ERC721 Collection ID -> Offer Parameters
    mapping(uint256 => Offer) public offers;
    /// Map token id to payment address
    mapping(uint256 => address) public paymentTokenHistory;
    /// @notice KYC Garment Designers -> Number of times they have sold in this marketplace (To set fee accordingly)
    mapping(address => uint256) public numberOfTimesSold;
    /// @notice Garment Collection ID -> Buyer -> Last purhcased time
    mapping(uint256 => mapping(address => uint256)) public lastPurchasedTime;
    /// @notice Garment ERC721 NFT - the only NFT that can be offered in this contract
    IDigitalaxGarmentNFT public garmentNft;
    /// @notice Garment NFT Collection
    DigitalaxGarmentCollectionV2 public garmentCollection;
    /// @notice oracle for TOKEN/USDT exchange rate
    IDripOracle public oracle;
    /// @notice responsible for enforcing admin access
    DigitalaxAccessControls public accessControls;
    /// @notice where to send platform fee funds to
    address payable public platformFeeRecipient;
    /// @notice for pausing marketplace functionalities
    bool public isPaused;
    /// @notice the erc20 token
    address public wethERC20Token;
    /// @notice for freezing erc20 payment option
    bool public freezeERC20Payment;

    /// @notice for storing information from oracle
    mapping (address => uint256) public lastOracleQuote;

    address public MATIC_TOKEN = 0x0000000000000000000000000000000000001010;

    modifier whenNotPaused() {
        require(!isPaused, "Function is currently paused");
        _;
    }
    receive() external payable {
    }
    function initialize(
        DigitalaxAccessControls _accessControls,
        IDigitalaxGarmentNFT _garmentNft,
        DigitalaxGarmentCollectionV2 _garmentCollection,
        IDripOracle _oracle,
        address payable _platformFeeRecipient,
        address _wethERC20Token,
        address _trustedForwarder
    ) public initializer {
        require(address(_accessControls) != address(0), "DigitalaxMarketplace: Invalid Access Controls");
        require(address(_garmentNft) != address(0), "DigitalaxMarketplace: Invalid NFT");
        require(address(_garmentCollection) != address(0), "DigitalaxMarketplace: Invalid Collection");
        require(address(_oracle) != address(0), "DigitalaxMarketplace: Invalid Oracle");
        require(_platformFeeRecipient != address(0), "DigitalaxMarketplace: Invalid Platform Fee Recipient");
        require(_wethERC20Token != address(0), "DigitalaxMarketplace: Invalid ERC20 Token");
        oracle = _oracle;
        accessControls = _accessControls;
        garmentNft = _garmentNft;
        garmentCollection = _garmentCollection;
        wethERC20Token = _wethERC20Token;
        platformFeeRecipient = _platformFeeRecipient;
        trustedForwarder = _trustedForwarder;
        lastOracleQuote[address(wethERC20Token)] = 1e18;

        emit DigitalaxMarketplaceContractDeployed();
    }


    /**
     * Override this function.
     * This version is to keep track of BaseRelayRecipient you are using
     * in your contract.
     */
    function versionRecipient() external view override returns (string memory) {
        return "1";
    }

    function setTrustedForwarder(address _trustedForwarder) external  {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxMaterials.setTrustedForwarder: Sender must be admin"
        );
        trustedForwarder = _trustedForwarder;
    }

    // This is to support Native meta transactions
    // never use msg.sender directly, use _msgSender() instead
    function _msgSender()
    internal
    view
    returns (address payable sender)
    {
        return BaseRelayRecipient.msgSender();
    }

    /**
     @notice Method for updating oracle
     @dev Only admin
     @param _oracle new oracle
     */
    function updateOracle(IDripOracle _oracle) external {
    require(
        accessControls.hasAdminRole(_msgSender()),
        "DigitalaxAuction.updateOracle: Sender must be admin"
        );

        oracle = _oracle;
        emit UpdateOracle(address(_oracle));
    }

    /**
    // TODO - make this convert from usdt to token
     @notice Private method to estimate USDT conversion for paying
     @param _token Payment Token
     @param _amountInUSDT Token amount in wei
     */
    function _estimateTokenAmount(address _token, uint256 _amountInUSDT) public returns (uint256) {
        (uint256 exchangeRate, bool rateValid) = oracle.getData(address(_token));
        require(rateValid, "DigitalaxMarketplace.estimateTokenAmount: Oracle data is invalid");
        lastOracleQuote[_token] = exchangeRate;

        return _amountInUSDT.mul(exchangeRate).div(1e18);
    }

    /**
    // TODO - make this convert from usdt to eth
    // TODO will need some extra variable to note the specific ETH conversion
     @notice Private method to estimate ETH for paying
     @param _amountInUSDT Token amount in wei
     */
    function _estimateETHAmount(uint256 _amountInUSDT) public returns (uint256) {
        (uint256 exchangeRate, bool rateValid) = oracle.getData(address(wethERC20Token));
        require(rateValid, "DigitalaxMarketplace.estimateETHAmount: Oracle data is invalid");
        lastOracleQuote[address(wethERC20Token)] = exchangeRate;

        return _amountInUSDT.mul(exchangeRate).div(1e18);
    }

    /**
     @notice Creates a new offer for a given garment
     @dev Only the owner of a garment can create an offer and must have ALREADY approved the contract
     @dev In addition to owning the garment, the sender also has to have the MINTER or ADMIN role.
     @dev End time for the offer will be in the future, at a time from now till expiry duration
     @dev There cannot be a duplicate offer created
     @param _garmentCollectionId Collection ID of the garment being offered to marketplace
     @param _primarySalePrice Garment cannot be sold for less than this
     @param _startTimestamp when the sale starts
     @param _endTimestamp when the sale ends
     @param _discountToPayERC20 Percentage to discount from overall purchase price if USDT (ERC20) used, 1 decimal place (i.e. 5% is 50)
     @param _maxAmount Max number of products from this collection that someone can buy
     */
    function createOffer(
        uint256 _garmentCollectionId,
        uint256 _primarySalePrice,
        uint256 _startTimestamp,
        uint256 _endTimestamp,
        uint256 _discountToPayERC20,
        uint256 _maxAmount
    ) external {
        // Ensure caller has privileges
        require(
            accessControls.hasMinterRole(_msgSender()) || accessControls.hasAdminRole(_msgSender()),
            "DigitalaxMarketplace.createOffer: Sender must have the minter or admin role"
        );
        // Ensure the collection does exists
        require(garmentCollection.getSupply(_garmentCollectionId) > 0, "DigitalaxMarketplace.createOffer: Collection does not exist");

        // Ensure the maximum purchaseable amount is less than collection supply
        require(_maxAmount <= garmentCollection.getSupply(_garmentCollectionId), "DigitalaxMarketplace.createOffer: Invalid Maximum amount");
        // Ensure the end time stamp is valid
        require(_endTimestamp > _startTimestamp, "DigitalaxMarketplace.createOffer: Invalid end time");

        _createOffer(
            _garmentCollectionId,
            _primarySalePrice,
            _startTimestamp,
            _endTimestamp,
            _discountToPayERC20,
            _maxAmount,
            false
        );
    }

    function batchBuyOffer(uint256[] memory _garmentCollectionIds, address _paymentToken, uint256 _orderId, uint256 _shippingUSD) external payable whenNotPaused nonReentrant {
        require(_msgSender().isContract() == false, "DripMarketplace.buyOffer: No contracts permitted");
        require(_paymentToken != address(0), "DripMarketplace.buyOffer: Payment token cannot be zero address");

        uint256[] memory collectionIds = _garmentCollectionIds;

        for(uint i = 0; i < collectionIds.length; i += 1) {
            buyOffer(collectionIds[i], _paymentToken, _orderId, _shippingUSD);
        }
    }

    /**
     @notice Buys an open offer with eth or erc20
     @dev Only callable when the offer is open
     @dev Bids from smart contracts are prohibited - a user must buy directly from their address
     @dev Contract must have been approved on the buy offer previously
     @dev The sale must have started (start time) to make a successful buy
     @param _garmentCollectionId Collection ID of the garment being offered
     */
    function buyOffer(uint256 _garmentCollectionId, address _paymentToken, uint256 _orderId, uint256 _shippingUSD) internal {
        // Check the offers to see if this is a valid
        require(_msgSender().isContract() == false, "DigitalaxMarketplace.buyOffer: No contracts permitted");
        require(_isFinished(_garmentCollectionId) == false, "DigitalaxMarketplace.buyOffer: Sale has been finished");
        require(_paymentToken != address(0), "DripMarketplace.buyOffer: Payment token cannot be zero address");
        require(oracle.checkValidToken(_paymentToken), "DripMarketplace.buyOffer: Not valid payment erc20");

        Offer storage offer = offers[_garmentCollectionId];
        require(
            garmentCollection.balanceOfAddress(_garmentCollectionId, _msgSender()) < offer.maxAmount,
            "DigitalaxMarketplace.buyOffer: Can't purchase over maximum amount"
        );
        require(!offer.paused, "DigitalaxMarketplace.buyOffer: Can't purchase when paused");

        uint256[] memory bundleTokenIds = garmentCollection.getTokenIds(_garmentCollectionId);
        uint256 bundleTokenId = bundleTokenIds[offer.availableIndex];
        uint256 maxShare = 1000;

        // Ensure this contract is still approved to move the token
        require(garmentNft.isApproved(bundleTokenId, address(this)), "DigitalaxMarketplace.buyOffer: offer not approved");
        require(_getNow() >= offer.startTime, "DigitalaxMarketplace.buyOffer: Purchase outside of the offer window");
        require(!freezeERC20Payment, "DigitalaxMarketplace.buyOffer: erc20 payments currently frozen");

        uint256 amountOfDiscountOnPaymentTokenPrice = offer.primarySalePrice.mul(offer.discountToPayERC20).div(maxShare);

        uint256 priceInPaymentToken = _estimateTokenAmount(_paymentToken, offer.primarySalePrice.add(_shippingUSD).sub(amountOfDiscountOnPaymentTokenPrice));

        // If it is MATIC, needs to be send as msg.value
        if (_paymentToken == MATIC_TOKEN) {
            require(msg.value >= priceInPaymentToken, "DigitalaxMarketplace.buyOffer: Failed to supply funds");

            // Send platform fee in ETH to the platform fee recipient, there is a discount that is subtracted from this
            (bool platformTransferSuccess,) = platformFeeRecipient.call{value : priceInPaymentToken}("");
            require(platformTransferSuccess, "DigitalaxMarketplace.buyOffer: Failed to send platform fee");

        } else {
            // Check that there is enough ERC20 to cover the rest of the value (minus the discount already taken)
            require(IERC20(_paymentToken).allowance(_msgSender(), address(this)) >= priceInPaymentToken, "DigitalaxMarketplace.buyOffer: Failed to supply ERC20 Allowance");

            IERC20(_paymentToken).transferFrom(
                _msgSender(),
                platformFeeRecipient,
                priceInPaymentToken);
        }

        offer.availableIndex = offer.availableIndex.add(1);
        // Record the primary sale price for the garment
        garmentNft.setPrimarySalePrice(bundleTokenId, _estimateETHAmount(offer.primarySalePrice));
        // Transfer the token to the purchaser
        garmentNft.safeTransferFrom(garmentNft.ownerOf(bundleTokenId), _msgSender(), bundleTokenId);
        lastPurchasedTime[_garmentCollectionId][_msgSender()] = _getNow();

        paymentTokenHistory[bundleTokenId] = _paymentToken;

        emit OfferPurchased(bundleTokenId, _garmentCollectionId, _shippingUSD, priceInPaymentToken, _orderId);
    }
    /**
     @notice Cancels an inflight and un-resulted offer
     @dev Only admin
     @param _garmentCollectionId Token ID of the garment being offered
     */
    function cancelOffer(uint256 _garmentCollectionId) external nonReentrant {
        // Admin only resulting function
        require(
            accessControls.hasAdminRole(_msgSender()) || accessControls.hasMinterRole(_msgSender()),
            "DigitalaxMarketplace.cancelOffer: Sender must be admin or minter contract"
        );
        // Check valid and not resulted
        Offer storage offer = offers[_garmentCollectionId];
        require(offer.primarySalePrice != 0, "DigitalaxMarketplace.cancelOffer: Offer does not exist");
        // Remove offer
        delete offers[_garmentCollectionId];
        emit OfferCancelled(_garmentCollectionId);
    }

    /**
     @notice Toggling the pause flag
     @dev Only admin
     */
    function togglePaused(uint256 _garmentCollectionId) external {
        require(accessControls.hasAdminRole(_msgSender()), "DigitalaxMarketplace.togglePaused: Sender must be admin");
        Offer storage offer = offers[_garmentCollectionId];
        offer.paused = !offer.paused;
        emit CollectionPauseToggled(_garmentCollectionId, offer.paused);
    }

    /**
     @notice Toggling the pause flag
     @dev Only admin
     */
    function toggleIsPaused() external {
        require(accessControls.hasAdminRole(_msgSender()), "DigitalaxMarketplace.toggleIsPaused: Sender must be admin");
        isPaused = !isPaused;
        emit PauseToggled(isPaused);
    }

    /**
     @notice Toggle freeze ERC20
     @dev Only admin
     */
    function toggleFreezeERC20Payment() external {
        require(accessControls.hasAdminRole(_msgSender()), "DigitalaxMarketplace.toggleFreezeERC20Payment: Sender must be admin");
        freezeERC20Payment = !freezeERC20Payment;
        emit FreezeERC20PaymentToggled(freezeERC20Payment);
    }

    /**
     @notice Update the marketplace discount
     @dev Only admin
     @dev This discount is taken away from the received fees, so the discount cannot exceed the platform fee
     @param _garmentCollectionId Collection ID of the garment being offered
     @param _marketplaceDiscount New marketplace discount
     */
    function updateMarketplaceDiscountToPayInErc20(uint256 _garmentCollectionId, uint256 _marketplaceDiscount) external {
        require(accessControls.hasAdminRole(_msgSender()), "DigitalaxMarketplace.updateMarketplaceDiscountToPayInErc20: Sender must be admin");
        require(_marketplaceDiscount < 1000, "DigitalaxMarketplace.updateMarketplaceDiscountToPayInErc20: Discount cannot be greater then fee");
        offers[_garmentCollectionId].discountToPayERC20 = _marketplaceDiscount;
        emit UpdateMarketplaceDiscountToPayInErc20(_garmentCollectionId, _marketplaceDiscount);
    }

    /**
     @notice Update the offer primary sale price
     @dev Only admin
     @param _garmentCollectionId Collection ID of the garment being offered
     @param _primarySalePrice New price
     */
    function updateOfferPrimarySalePrice(uint256 _garmentCollectionId, uint256 _primarySalePrice) external {
        require(accessControls.hasAdminRole(_msgSender()), "DigitalaxMarketplace.updateOfferPrimarySalePrice: Sender must be admin");

        offers[_garmentCollectionId].primarySalePrice = _primarySalePrice;
        emit UpdateOfferPrimarySalePrice(_garmentCollectionId, _primarySalePrice);
    }

    /**
     @notice Update the offer max amount
     @dev Only admin
     @param _garmentCollectionId Collection ID of the garment being offered
     @param _maxAmount New amount
     */
    function updateOfferMaxAmount(uint256 _garmentCollectionId, uint256 _maxAmount) external {
        require(accessControls.hasAdminRole(_msgSender()), "DigitalaxMarketplace.updateOfferMaxAmount: Sender must be admin");

        offers[_garmentCollectionId].maxAmount = _maxAmount;
        emit UpdateOfferMaxAmount(_garmentCollectionId, _maxAmount);
    }

    /**
     @notice Update the offer start and end time
     @dev Only admin
     @param _garmentCollectionId Collection ID of the garment being offered
     @param _startTime start time
     @param _endTime end time
     */
    function updateOfferStartEndTime(uint256 _garmentCollectionId, uint256 _startTime, uint256 _endTime) external {
        require(accessControls.hasAdminRole(_msgSender()), "DigitalaxMarketplace.updateOfferPrimarySalePrice: Sender must be admin");
        require(_endTime > _startTime, "DigitalaxMarketplace.createOffer: Invalid end time");
        offers[_garmentCollectionId].startTime = _startTime;
        offers[_garmentCollectionId].endTime = _endTime;
        emit UpdateOfferStartEnd(_garmentCollectionId, _startTime, _endTime);
    }

    /**
     @notice Method for updating the access controls contract used by the NFT
     @dev Only admin
     @param _accessControls Address of the new access controls contract (Cannot be zero address)
     */
    function updateAccessControls(DigitalaxAccessControls _accessControls) external {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxMarketplace.updateAccessControls: Sender must be admin"
        );
        require(address(_accessControls) != address(0), "DigitalaxMarketplace.updateAccessControls: Zero Address");
        accessControls = _accessControls;
        emit UpdateAccessControls(address(_accessControls));
    }

    /**
     @notice Method for updating platform fee address
     @dev Only admin
     @param _platformFeeRecipient payable address the address to sends the funds to
     */
    function updatePlatformFeeRecipient(address payable _platformFeeRecipient) external {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxMarketplace.updatePlatformFeeRecipient: Sender must be admin"
        );
        require(_platformFeeRecipient != address(0), "DigitalaxMarketplace.updatePlatformFeeRecipient: Zero address");
        platformFeeRecipient = _platformFeeRecipient;
        emit UpdatePlatformFeeRecipient(_platformFeeRecipient);
    }

    ///////////////
    // Accessors //
    ///////////////
    /**
     @notice Method for getting all info about the offer
     @param _garmentCollectionId Token ID of the garment being offered
     */
    function getOffer(uint256 _garmentCollectionId)
    external
    view
    returns (uint256 _primarySalePrice, uint256 _startTime, uint256 _endTime, uint256 _availableAmount, uint256 _discountToPayERC20) {
        Offer storage offer = offers[_garmentCollectionId];
        uint256 availableAmount = garmentCollection.getSupply(_garmentCollectionId).sub(offer.availableIndex);
        return (
            offer.primarySalePrice,
            offer.startTime,
            offer.endTime,
            availableAmount,
            offer.discountToPayERC20
        );
    }

    ///////////////
    // Accessors //
    ///////////////
    /**
     @notice Method for getting all info about the offer
     @param _garmentCollectionId Token ID of the garment being offered
     */
    function getOfferMaxAmount(uint256 _garmentCollectionId)
    external
    view
    returns (uint256 _maxAmount) {
        Offer storage offer = offers[_garmentCollectionId];
        return (
            offer.maxAmount
        );
    }

    /////////////////////////
    // Internal and Private /
    /////////////////////////
    function _getNow() internal virtual view returns (uint256) {
        return block.timestamp;
    }

    function _isCollectionApproved(uint256 _collectionId, address _address) internal virtual returns (bool) {
        uint256[] memory tokenIds = garmentCollection.getTokenIds(_collectionId);
        for (uint i = 0; i < tokenIds.length; i ++) {
            if (!garmentNft.isApproved(tokenIds[i], _address)) {
                return false;
            }
        }
        return true;
    }

    /**
     @notice Private method to check if the sale is finished
     @param _garmentCollectionId Id of the collection.
     */
    function _isFinished(uint256 _garmentCollectionId) internal virtual view returns (bool) {
        Offer memory offer = offers[_garmentCollectionId];

        if (offer.endTime < _getNow()) {
            return true;
        }

        uint256 availableAmount = garmentCollection.getSupply(_garmentCollectionId).sub(offer.availableIndex);
        return availableAmount <= 0;
    }

    /**
     @notice Private method doing the heavy lifting of creating an offer
     @param _garmentCollectionId Collection ID of the garment being offered
     @param _primarySalePrice Garment cannot be sold for less than this
     @param _startTimestamp Unix epoch in seconds for the offer start time
     @param _discountToPayERC20 Percentage to discount from overall purchase price if USDT (ERC20) used, 1 decimal place (i.e. 5% is 50)
     */
    function _createOffer(
        uint256 _garmentCollectionId,
        uint256 _primarySalePrice,
        uint256 _startTimestamp,
        uint256 _endTimestamp,
        uint256 _discountToPayERC20,
        uint256 _maxAmount,
        bool _paused
    ) private {
        // The discount cannot be greater than the platform fee
        require(1000 > _discountToPayERC20 , "DigitalaxMarketplace.createOffer: The discount is taken out of platform fee, discount cannot be greater");
        // Ensure a token cannot be re-listed if previously successfully sold
        require(offers[_garmentCollectionId].startTime == 0, "DigitalaxMarketplace.createOffer: Cannot duplicate current offer");
        // Setup the new offer
        offers[_garmentCollectionId] = Offer({
            primarySalePrice : _primarySalePrice,
            startTime : _startTimestamp,
            endTime: _endTimestamp,
            availableIndex : 0,
            discountToPayERC20: _discountToPayERC20,
            maxAmount: _maxAmount,
            paused: _paused
        });
        emit OfferCreated(_garmentCollectionId, _primarySalePrice, _startTimestamp, _endTimestamp, _discountToPayERC20, _maxAmount);
    }

    /**
    * @notice Reclaims ERC20 Compatible tokens for entire balance - can be used for MATIC MRC20
    * @dev Only access controls admin
    * @param _tokenContract The address of the token contract
    */
    function reclaimERC20(address _tokenContract) external {
        require(
            accessControls.hasAdminRole(_msgSender()),
            "DigitalaxMarketplace.reclaimERC20: Sender must be admin"
        );
        require(_tokenContract != address(0), "Invalid address");
        IERC20 token = IERC20(_tokenContract);
        uint256 balance = token.balanceOf(address(this));
        require(token.transfer(_msgSender(), balance), "Transfer failed");
    }

    /**
     @notice Method for getting all info about the offer
     @param _garmentCollectionId Token ID of the garment being offered
     */
    function getOfferAvailableIndex(uint256 _garmentCollectionId)
    external
    view
    returns (uint256 _availableIndex) {
        Offer storage offer = offers[_garmentCollectionId];
        return (
            offer.availableIndex
        );
    }

    function updateOfferAvailableIndex(uint256 _garmentCollectionId, uint256 _availableIndex) external
    {
        require(accessControls.hasAdminRole(_msgSender()), "DripMarketplace.updateOfferAvailableIndex: Sender must be admin");

        Offer storage offer = offers[_garmentCollectionId];
        offer.availableIndex = _availableIndex;
        emit UpdateOfferAvailableIndex(_garmentCollectionId, _availableIndex);
    }
}

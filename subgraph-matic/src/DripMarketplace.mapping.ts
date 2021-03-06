import {ONE} from "./constants";

import {
    OfferCreated,
    OfferPurchased,
    UpdateOfferPrimarySalePrice,
    DripMarketplace as DripMarketplaceContract,
    OfferCancelled,
    DigitalaxMarketplaceContractDeployed,
    UpdateMarketplaceDiscountToPayInErc20
} from "../generated/DripMarketplace/DripMarketplace";

import {
    DripMarketplaceOffer,
    DripMarketplacePurchaseHistory,
    DigitalaxGarmentV2Collection,
} from "../generated/schema";
import {loadOrCreateDripGlobalStats} from "./factory/DripGlobalStats.factory";
import { ZERO } from "./constants";
import { loadDayFromEvent } from "./factory/DripDay.factory";
import {store} from "@graphprotocol/graph-ts/index";
//
export function handleMarketplaceDeployed(event: DigitalaxMarketplaceContractDeployed): void {
    let contract = DripMarketplaceContract.bind(event.address);
    let globalStats = loadOrCreateDripGlobalStats();
    globalStats.save();
}

export function handleUpdateMarketplaceDiscountToPayInErc20(event: UpdateMarketplaceDiscountToPayInErc20): void {
    let offer = DripMarketplaceOffer.load(event.params.garmentCollectionId.toString());
    offer.discountToPayERC20 = event.params.discount;
    offer.save();
}

export function handleOfferCreated(event: OfferCreated): void {
    let contract = DripMarketplaceContract.bind(event.address);
    let offer = new DripMarketplaceOffer(event.params.garmentCollectionId.toString());
    let offerData = contract.getOffer(event.params.garmentCollectionId);
    offer.primarySalePrice = offerData.value0;
    offer.startTime = offerData.value1;
    offer.endTime = offerData.value2;
    offer.garmentCollection = event.params.garmentCollectionId.toString();
    offer.amountSold = ZERO;
    offer.discountToPayERC20 = offerData.value4;
    offer.save();
}

export function handleOfferPrimarySalePriceUpdated(event: UpdateOfferPrimarySalePrice): void {
    let offer = DripMarketplaceOffer.load(event.params.garmentCollectionId.toString());
    offer.primarySalePrice = event.params.primarySalePrice;
    offer.save();
}

export function handleOfferPurchased(event: OfferPurchased): void {
    let contract = DripMarketplaceContract.bind(event.address);
    let collection = DigitalaxGarmentV2Collection.load(event.params.garmentCollectionId.toString());
    let history = new DripMarketplacePurchaseHistory(event.params.bundleTokenId.toString());
    let offerData = contract.getOffer(event.params.garmentCollectionId);

    history.eventName = "Purchased";
    history.timestamp = event.block.timestamp;
    history.token = event.params.bundleTokenId.toString();
    history.transactionHash = event.transaction.hash;
    history.orderId = event.params.offerId;

    history.buyer = event.transaction.from;
    history.paymentTokenTransferredAmount = event.params.tokenTransferredAmount;
    let paymentToken = contract.paymentTokenHistory(event.params.bundleTokenId);
    history.paymentToken = paymentToken.toHexString();
    history.garmentCollectionId = event.params.garmentCollectionId;
    history.rarity = collection.rarity;

    history.value = offerData.value0; // USD value primary sale price
    history.shippingUsd = event.params.shippingAmount;
    history.discountToPayERC20 = offerData.value4;
    history.usdPaymentTokenExchange = contract.lastOracleQuote(paymentToken);
    let weth = contract.wethERC20Token();
    history.usdEthExchange = contract.lastOracleQuote(weth);

    let day = loadDayFromEvent(event);
    let globalStats = loadOrCreateDripGlobalStats();

    globalStats.totalMarketplaceSalesInUSD = globalStats.totalMarketplaceSalesInUSD.plus(history.value);
    day.totalMarketplaceVolumeInUSD = day.totalMarketplaceVolumeInUSD.plus(history.value);

    globalStats.usdETHConversion = contract.lastOracleQuote(weth);

    day.save();
    history.save();
    globalStats.save();

    let offer = DripMarketplaceOffer.load(event.params.garmentCollectionId.toString());
    offer.amountSold = offer.amountSold.plus(ONE);
    offer.save();

    collection.valueSold = collection.valueSold.plus(history.value);
    collection.save();
}

export function handleOfferCancelled(event: OfferCancelled): void {
    let offer = DripMarketplaceOffer.load(event.params.bundleTokenId.toString());
    store.remove('DripMarketplaceOffer', event.params.bundleTokenId.toString());
    offer.save();
}

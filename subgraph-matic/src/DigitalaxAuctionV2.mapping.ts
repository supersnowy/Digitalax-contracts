import {BigInt} from "@graphprotocol/graph-ts/index";

import {
    AuctionCancelled,
    AuctionCreated,
    AuctionResulted,
    BidPlaced,
    BidWithdrawn,
    DigitalaxAuctionV2,
    DigitalaxAuctionContractDeployed,
    UpdateAuctionEndTime,
    UpdateAuctionReservePrice,
    UpdateAuctionStartTime,
    UpdateBidWithdrawalLockTime, UpdateMinBidIncrement, UpdatePlatformFee, UpdatePlatformFeeRecipient
} from "../generated/DigitalaxAuctionV2/DigitalaxAuctionV2";

import {
    DigitalaxGarmentV2Auction,
    DigitalaxGarmentV2,
    DigitalaxGarmentV2AuctionHistory,
    DigitalaxAuctionV2Contract
} from "../generated/schema"

import {ZERO} from "./constants";
import {loadOrCreateGarmentDesigner} from "./factory/DigitalaxGarmentDesigner.factory";
import {loadOrCreateDigitalaxCollectorV2} from "./factory/DigitalaxCollectorV2.factory";
import {loadDayFromEvent} from "./factory/Day.factory";
import {loadOrCreateGarmentNFTV2GlobalStats} from "./factory/DigitalaxGarmentNFTV2GlobalStats.factory";

export function handleAuctionCreated(event: AuctionCreated): void {
    let contract = DigitalaxAuctionV2.bind(event.address);
    let tokenId = event.params.garmentTokenId;

    let garmentDesigner = loadOrCreateGarmentDesigner(tokenId.toString());
    let listings = garmentDesigner.listings;
    listings.push(tokenId.toString());
    garmentDesigner.listings = listings;
    garmentDesigner.save();

    // Auction Created event
    let eventId = tokenId.toString()
        .concat("-")
        .concat(event.transaction.hash.toHexString())
        .concat("-")
        .concat(event.transaction.index.toString());

    let auctionEvent = new DigitalaxGarmentV2AuctionHistory(eventId);
    auctionEvent.token = tokenId.toString();
    auctionEvent.eventName = "AuctionCreated"
    auctionEvent.timestamp = event.block.timestamp
    auctionEvent.transactionHash = event.transaction.hash
    auctionEvent.save()

    // TODO: handle re-listing
    let auction = new DigitalaxGarmentV2Auction(tokenId.toString());
    auction.garment = tokenId.toString();
    auction.designer = garmentDesigner.id;
    auction.history = auctionEvent.id;
    auction.contract = event.address.toHexString();

    // Auction config
    let auctionResult = contract.auctions(tokenId);
    auction.reservePrice = auctionResult.value0;
    auction.startTime = auctionResult.value1;
    auction.endTime = auctionResult.value2;
    auction.resulted = auctionResult.value3;
    auction.resultedTime = event.block.timestamp;
    auction.save();

    loadOrCreateGarmentNFTV2GlobalStats();
}

export function handleDigitalaxAuctionContractDeployed(event: DigitalaxAuctionContractDeployed): void {
    let contract = DigitalaxAuctionV2.bind(event.address);

    let auctionConfig = new DigitalaxAuctionV2Contract(event.address.toHexString());
    auctionConfig.minBidIncrement = contract.minBidIncrement();
    auctionConfig.bidWithdrawalLockTime = contract.bidWithdrawalLockTime();
    auctionConfig.platformFee = contract.platformFee();
    auctionConfig.platformFeeRecipient = contract.platformFeeRecipient();
    auctionConfig.totalSales = ZERO;
    auctionConfig.save();
}

export function handleBidPlaced(event: BidPlaced): void {
    let contract = DigitalaxAuctionV2.bind(event.address);
    let tokenId = event.params.garmentTokenId;

    let auction = DigitalaxGarmentV2Auction.load(tokenId.toString());

    // Record bid as part of day
    let day = loadDayFromEvent(event);

    let topBidder = contract.getHighestBidder(event.params.garmentTokenId)
    let bidDeltaWithPreviousBid = ZERO;
    if (!auction.topBidder) {
        bidDeltaWithPreviousBid = day.totalBidValue.plus(topBidder.value1);
    } else {
        // This is key - we want to record the difference between the last highest bid and this new bid on this day
        bidDeltaWithPreviousBid = day.totalBidValue.plus(topBidder.value1.minus((auction.topBid as BigInt)));
    }

    day.totalBidValue = bidDeltaWithPreviousBid;
    day.totalNetBidActivity = day.totalBidValue.minus(day.totalWithdrawalValue);

    day.save();

    let globalStats = loadOrCreateGarmentNFTV2GlobalStats();
    globalStats.totalActiveBidsValue = globalStats.totalActiveBidsValue.plus(bidDeltaWithPreviousBid);
    globalStats.save();

    // Record top bidder
    auction.topBidder = loadOrCreateDigitalaxCollectorV2(event.params.bidder).id
    auction.topBid = topBidder.value1
    auction.lastBidTime = topBidder.value2
    auction.save()

    let eventId = tokenId.toString()
        .concat("-")
        .concat(event.transaction.hash.toHexString())
        .concat("-")
        .concat(event.transaction.index.toString());

    // Record event
    let auctionEvent = new DigitalaxGarmentV2AuctionHistory(eventId);
    auctionEvent.token = DigitalaxGarmentV2.load(event.params.garmentTokenId.toString()).id
    auctionEvent.eventName = "BidPlaced"
    auctionEvent.bidder = loadOrCreateDigitalaxCollectorV2(event.params.bidder).id
    auctionEvent.timestamp = event.block.timestamp
    auctionEvent.value = event.params.bid
    auctionEvent.transactionHash = event.transaction.hash
    auctionEvent.save()
}

export function handleBidWithdrawn(event: BidWithdrawn): void {
    let tokenId = event.params.garmentTokenId;

    let eventId = tokenId.toString()
        .concat("-")
        .concat(event.transaction.hash.toHexString())
        .concat("-")
        .concat(event.transaction.index.toString());

    let auctionEvent = new DigitalaxGarmentV2AuctionHistory(eventId);
    auctionEvent.token = DigitalaxGarmentV2.load(event.params.garmentTokenId.toString()).id
    auctionEvent.eventName = "BidWithdrawn"
    auctionEvent.bidder = loadOrCreateDigitalaxCollectorV2(event.params.bidder).id
    auctionEvent.timestamp = event.block.timestamp
    auctionEvent.value = event.params.bid
    auctionEvent.transactionHash = event.transaction.hash
    auctionEvent.save()

    // Clear down bids
    let auction = DigitalaxGarmentV2Auction.load(tokenId.toString());
    auction.topBidder = null
    auction.topBid = null
    auction.lastBidTime = null
    auction.save();

    // Record withdrawal as part of day
    let day = loadDayFromEvent(event);
    day.totalWithdrawalValue = day.totalWithdrawalValue.plus(event.params.bid);
    day.totalNetBidActivity = day.totalBidValue.minus(day.totalWithdrawalValue);
    day.save();

    let globalStats = loadOrCreateGarmentNFTV2GlobalStats();
    globalStats.totalActiveBidsValue = globalStats.totalActiveBidsValue.minus(event.params.bid);
    globalStats.save();
}

export function handleAuctionResulted(event: AuctionResulted): void {
    let tokenId = event.params.garmentTokenId;

    let eventId = tokenId.toString()
        .concat("-")
        .concat(event.transaction.hash.toHexString())
        .concat("-")
        .concat(event.transaction.index.toString());

    let auctionEvent = new DigitalaxGarmentV2AuctionHistory(eventId);
    auctionEvent.token = DigitalaxGarmentV2.load(event.params.garmentTokenId.toString()).id
    auctionEvent.eventName = "AuctionResulted"
    auctionEvent.bidder = loadOrCreateDigitalaxCollectorV2(event.params.winner).id
    auctionEvent.timestamp = event.block.timestamp
    auctionEvent.value = event.params.winningBid
    auctionEvent.transactionHash = event.transaction.hash
    auctionEvent.save()

    // Record winning bid
    let auctionConfig = DigitalaxAuctionV2Contract.load(event.address.toHexString());
    auctionConfig.totalSales = auctionConfig.totalSales.plus(event.params.winningBid)

    // Result the auction
    let auction = DigitalaxGarmentV2Auction.load(tokenId.toString());
    auction.resulted = true
    auction.resultedTime = event.block.timestamp
    auction.save();

    // Record global stats
    let globalStats = loadOrCreateGarmentNFTV2GlobalStats();
    globalStats.totalActiveBidsValue = globalStats.totalActiveBidsValue.minus(event.params.winningBid);
    globalStats.totalSalesValue = globalStats.totalSalesValue.plus(event.params.winningBid);
    globalStats.save();
}

export function handleAuctionCancelled(event: AuctionCancelled): void {
    let tokenId = event.params.garmentTokenId;
  
    let eventId = tokenId.toString()
        .concat("-")
        .concat(event.transaction.hash.toHexString())
        .concat("-")
        .concat(event.transaction.index.toString());
  
    let auctionEvent = new DigitalaxGarmentV2AuctionHistory(eventId);
    let garment = DigitalaxGarmentV2.load(event.params.garmentTokenId.toString());
    if (garment) {
        auctionEvent.token = DigitalaxGarmentV2.load(event.params.garmentTokenId.toString()).id
        auctionEvent.eventName = "AuctionCancelled"
        auctionEvent.timestamp = event.block.timestamp
        auctionEvent.transactionHash = event.transaction.hash
        auctionEvent.save()
    }

    // Clear down bids
    let auction = DigitalaxGarmentV2Auction.load(tokenId.toString());
    if (auction) {
      if (auction.topBid) {
          // adjust global stats
          let globalStats = loadOrCreateGarmentNFTV2GlobalStats();
          globalStats.totalActiveBidsValue = globalStats.totalActiveBidsValue.minus((auction.topBid as BigInt));
          globalStats.save();
      }
    
      auction.topBidder = null
      auction.topBid = null
      auction.lastBidTime = null
      auction.save();
    }
}

export function handleUpdateBidWithdrawalLockTime(event: UpdateBidWithdrawalLockTime): void {
/*
    event UpdateBidWithdrawalLockTime(
        uint256 bidWithdrawalLockTime
    );
 */
    let auctionConfig = DigitalaxAuctionV2Contract.load(event.address.toHexString());
    auctionConfig.bidWithdrawalLockTime = event.params.bidWithdrawalLockTime;
    auctionConfig.save();
}

export function handleUpdateMinBidIncrement(event: UpdateMinBidIncrement): void {
/*
    event UpdateMinBidIncrement(
        uint256 minBidIncrement
    );
 */
    let auctionConfig = DigitalaxAuctionV2Contract.load(event.address.toHexString());
    auctionConfig.minBidIncrement = event.params.minBidIncrement;
    auctionConfig.save();
}

export function handleUpdateAuctionReservePrice(event: UpdateAuctionReservePrice): void {
/*
    event UpdateAuctionReservePrice(
        uint256 indexed garmentTokenId,
        uint256 reservePrice
    );
 */
    let auction = DigitalaxGarmentV2Auction.load(event.params.garmentTokenId.toString());
    auction.reservePrice = event.params.reservePrice
    auction.save();
}

export function handleUpdateAuctionStartTime(event: UpdateAuctionStartTime): void {
/*
    event UpdateAuctionStartTime(
        uint256 indexed garmentTokenId,
        uint256 startTime
    );
 */
    let auction = DigitalaxGarmentV2Auction.load(event.params.garmentTokenId.toString());
    auction.startTime = event.params.startTime
    auction.save();
}

export function handleUpdateAuctionEndTime(event: UpdateAuctionEndTime): void {
/*
    event UpdateAuctionEndTime(
        uint256 indexed garmentTokenId,
        uint256 endTime
    );
 */
    let auction = DigitalaxGarmentV2Auction.load(event.params.garmentTokenId.toString());
    auction.endTime = event.params.endTime
    auction.save();
}

export function handleUpdatePlatformFee(event: UpdatePlatformFee): void {
/*
event UpdatePlatformFee(
    uint256 platformFee
);
 */
    let auctionConfig = DigitalaxAuctionV2Contract.load(event.address.toHexString());
    auctionConfig.platformFee = event.params.platformFee;
    auctionConfig.save();
}

export function handleUpdatePlatformFeeRecipient(event: UpdatePlatformFeeRecipient): void {
/*
    event UpdatePlatformFeeRecipient(
        address payable platformFeeRecipient
    );
 */
    let auctionConfig = DigitalaxAuctionV2Contract.load(event.address.toHexString());
    auctionConfig.platformFeeRecipient = event.params.platformFeeRecipient;
    auctionConfig.save();
}

// const GuildNftStakingArtifact = require('../../artifacts/contracts/staking/GuildNFTStakingWeightV2.sol/GuildNFTStakingWeightV2.json');
// const GuildNftStakingArtifact = require('../../artifacts/contracts/staking/GuildNFTStakingWeightV2.sol/GuildNFTStakingWeightV2.json');
const { ethers, upgrades } = require("hardhat");

const {
    ether,
} = require('@openzeppelin/test-helpers');

const AccessControlsArtifact = require('../../artifacts/contracts/DigitalaxAccessControls.sol/DigitalaxAccessControls.json');

const _ = require('lodash');

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();

    const accessControlsAddress = "0xbe5c84e6b036cb41a7a6b5008b9427a5f4f1c9f5";
    const originalStakingAddress = "0xf0815348F626B0f4f434CAF9C5984694D85B50A1";
    const decoTokenAddress = "0x200f9621cbce6ed740071ba34fde85ee03f2e113";
    const decoOracleAddress = "0xcfb6d9134e2742512883e8d68c6166b480bf1875";
    const trustedForwarderAddress = "0x86C80a8aa58e0A4fa09A69624c31Ab2a6CAD56b8";
    const rewardsDistributed = "50442764192708333329873549";
    const tokenWhitelist = [
                            "0x7B2a989c4D1AD1B79a84CE2EB79dA5D8d9C2b7a7",
                            "0x2953399124f0cbb46d2cbacd8a89cf0599974963",
                            "0x2b9bd413852401a7e09c77de1fab53915f8f9336",
                            "0x5bc808062b6d36f0c6013c4ac662a8ba4f0cb5ea",
                            "0x2d0d9b4075e231bff33141d69df49ffcf3be7642",
                            "0xbccaa7acb552a2c7eb27c7eb77c2cc99580735b9",
                            "0xa5f1ea7df861952863df2e8d1312f7305dabf215",
                            "0xfd12ec7ea4b381a79c78fe8b2248b4c559011ffb"
                            ];



    const accessControls = new ethers.Contract(
        accessControlsAddress,
        AccessControlsArtifact.abi,
        deployer
    );

  const WhitelistedNFTStaking = await ethers.getContractFactory("GuildWhitelistedNFTStaking");
  const whitelistedNFTStaking = await WhitelistedNFTStaking.deploy();
  console.log('The whitelisted nft staking is deployed to:');
  console.log(whitelistedNFTStaking.address);

  const StakingWeightStorage = await ethers.getContractFactory("GuildNFTStakingWeightV2Storage");
  const instanceStakingWeightStorage = await upgrades.deployProxy(StakingWeightStorage, ["0x0000000000000000000000000000000000000000",accessControlsAddress]);
  await instanceStakingWeightStorage.deployed();

  const StakingWeight = await ethers.getContractFactory("GuildNFTStakingWeightV2");
  const instanceStakingWeight = await upgrades.deployProxy(StakingWeight,
      [originalStakingAddress,
          whitelistedNFTStaking.address,
        decoTokenAddress,
        accessControlsAddress,
        instanceStakingWeightStorage.address
      ]);
  await instanceStakingWeight.deployed();

  const StakingRewards = await ethers.getContractFactory("GuildNFTRewardsV2");
  const instanceStakingRewards = await upgrades.deployProxy(StakingRewards,
      [
          decoTokenAddress,
        accessControlsAddress,
        originalStakingAddress,
          whitelistedNFTStaking.address,
          decoOracleAddress,
          trustedForwarderAddress,
        rewardsDistributed
      ]);
  await instanceStakingRewards.deployed();

    const stakingInit = await whitelistedNFTStaking.initStaking(
        decoTokenAddress,
            accessControlsAddress,
            instanceStakingWeight.address,
            trustedForwarderAddress );
    await stakingInit.wait();

    await instanceStakingWeightStorage.updateWeightContract(instanceStakingWeight.address);

    console.log('tokens claimable');
    const setTokensClaimable = await whitelistedNFTStaking.setTokensClaimable(true);
    await setTokensClaimable.wait();
    console.log('minter');

    const acr2 = await accessControls.addMinterRole(instanceStakingRewards.address);
    await acr2.wait();

    console.log('weight points');
    await instanceStakingRewards.setWeightPoints('5000000000000000000000000000000000000', '5000000000000000000000000000000000000');

    console.log('rewardscontract');
    const updateRewardContract = await whitelistedNFTStaking.setRewardsContract(instanceStakingRewards.address);
    await updateRewardContract.wait();

    console.log('setrewards');
    await instanceStakingRewards.setRewards([0,1,2,3,4,5,6,7,8,9,10,11,12,13], Array(14).fill('4128750000000000000000000'));

    console.log('whitelisting');
    const whitelisted = await whitelistedNFTStaking.addWhitelistedTokens(tokenWhitelist);
    await whitelisted.wait();

  console.log('the tokens have been deployed');
  console.log(`The storage: ${instanceStakingWeightStorage.address} (make sure to update weight contract)`);
  console.log(`The weight: ${instanceStakingWeight.address} `);
  console.log(`The rewards: ${instanceStakingRewards.address} `);
  console.log(`The whitelisted nft staking: ${whitelistedNFTStaking.address} `);

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });

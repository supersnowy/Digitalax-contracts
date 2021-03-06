const NFTStakingArtifact = require('../../artifacts/contracts/staking/DigitalaxNFTStaking.sol/DigitalaxNFTStaking.json');

const fs = require('fs');
const _ = require('lodash');

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log(
      'Analyzing with following address',
      deployerAddress
  );

  const DIGITALAX_STAKING_ADDRESS = "0xd80eeB5aFfd3C419f2Cb05477372778862D26757"
  // const DIGITALAX_STAKING_ADDRESS = "0x2E4ae1f8E1463f450e9B01F20cee1590Bff4E1fC"


  const stakingContract =  new ethers.Contract(
      DIGITALAX_STAKING_ADDRESS,
      NFTStakingArtifact.abi,
      deployer
  );


  const metadata = require('./tokensmigrated.json');
  //  Data length
  console.log("number of tokens to check:")
  console.log(metadata.length)
  const datas = metadata;
  const MAX_NFT_SINGLE_TX = 100;
  const chunks = _.chunk(datas, MAX_NFT_SINGLE_TX);

  for(let i = 1; i< chunks.length ; i++){
    const x = chunks[i];
    const y = x.map((z)=>{return z["id"]});

    console.log(x);
    const update = await stakingContract.saveCurrentPrimarySalePrice(y);
    await update.wait();
    }

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });

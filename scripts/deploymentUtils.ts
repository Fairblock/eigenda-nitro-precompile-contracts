import { ethers } from 'hardhat'
import { ContractFactory, Contract, Overrides, BigNumber } from 'ethers'
import '@nomiclabs/hardhat-ethers'
import { run } from 'hardhat'
import {
  abi as UpgradeExecutorABI,
  bytecode as UpgradeExecutorBytecode,
} from '@offchainlabs/upgrade-executor/build/contracts/src/UpgradeExecutor.sol/UpgradeExecutor.json'
import { Toolkit4844 } from '../test/contract/toolkit4844'
import {
  ArbOwner__factory,
  ArbSys__factory,
  CacheManager__factory,
  EigenDABlobVerifierL1__factory,
} from '../build/types'

const INIT_CACHE_SIZE = 536870912
const INIT_DECAY = 10322197911
const ARB_OWNER_ADDRESS = '0x0000000000000000000000000000000000000070'
const ARB_SYS_ADDRESS = '0x0000000000000000000000000000000000000064'

// Define a verification function
export async function verifyContract(
  contractName: string,
  contractAddress: string,
  constructorArguments: any[] = [],
  contractPathAndName?: string // optional
): Promise<void> {
  try {
    if (process.env.DISABLE_VERIFICATION) return
    // Define the verification options with possible 'contract' property
    const verificationOptions: {
      contract?: string
      address: string
      constructorArguments: any[]
    } = {
      address: contractAddress,
      constructorArguments: constructorArguments,
    }

    // if contractPathAndName is provided, add it to the verification options
    if (contractPathAndName) {
      verificationOptions.contract = contractPathAndName
    }

    await run('verify:verify', verificationOptions)
    console.log(`Verified contract ${contractName} successfully.`)
  } catch (error: any) {
    if (error.message.includes('Already Verified')) {
      console.log(`Contract ${contractName} is already verified.`)
    } else {
      console.error(
        `Verification for ${contractName} failed with the following error: ${error.message}`
      )
    }
  }
}

// Function to handle contract deployment
export async function deployContract(
  contractName: string,
  signer: any,
  constructorArgs: any[] = [],
  verify: boolean = true,
  overrides?: Overrides
): Promise<Contract> {
  console.log('Deploying contract EigenDA x Arbitrum', contractName)
  const factory: ContractFactory = await ethers.getContractFactory(contractName)
  const connectedFactory: ContractFactory = factory.connect(signer)

  let deploymentArgs = [...constructorArgs]
  if (overrides) {
    deploymentArgs.push(overrides)
  }

  const contract: Contract = await connectedFactory.deploy(...deploymentArgs)
  await contract.deployTransaction.wait()
  console.log(`New ${contractName} created at address:`, contract.address)

  if (verify)
    await verifyContract(contractName, contract.address, constructorArgs)

  return contract
}


// Deploy blob verifier for the EigendaRollupManager 
// argument for rollup creator deployment on L1
// TODO: This logic will be deprecated in the future in favor of 
// embedding verifications into the service manager directl
export async function deployBlobVerifierL1(
  contractName: string,
  signer: any,
  constructorArgs: any[] = [],
  verify: boolean = true,
  overrides?: Overrides
): Promise<Contract> {
  console.log("Deploying contract EigenDA x Arbitrum", contractName)
  const eigenDARollupUtils = await deployContract('EigenDARollupUtils', signer, [], verify)
  console.log("EigenDARollupUtils deployed at", eigenDARollupUtils.address)

  const eigenda_blob_verifier = await ethers.getContractFactory(contractName, {
    libraries: {
        EigenDARollupUtils: eigenDARollupUtils.address
    }
  }) as EigenDABlobVerifierL1__factory

  const connectedFactory: ContractFactory = eigenda_blob_verifier.connect(signer)

  let deploymentArgs = [...constructorArgs]
  if (overrides) {
    deploymentArgs.push(overrides)
  }

  const contract: Contract = await connectedFactory.deploy(...deploymentArgs)
  await contract.deployTransaction.wait()
  console.log(`New ${contractName} created at address:`, contract.address)

  if (verify)
    await verifyContract(contractName, contract.address, constructorArgs)

  return contract
}

// Deploy upgrade executor from imported bytecode
export async function deployUpgradeExecutor(signer: any): Promise<Contract> {
  console.log("Deploying contract EigenDA x Arbitrum UpgradeExecutor")
  const upgradeExecutorFac = await ethers.getContractFactory(
    UpgradeExecutorABI,
    UpgradeExecutorBytecode
  )
  const connectedFactory: ContractFactory = upgradeExecutorFac.connect(signer)
  const upgradeExecutor = await connectedFactory.deploy()
  await upgradeExecutor.deployTransaction.wait()
  console.log("Upgrade executor deployed at", upgradeExecutor.address)
  return upgradeExecutor
}

const L1ServiceManagers = {
  1: "0x870679E138bCdf293b7Ff14dD44b70FC97e12fc0", // Ethereum
  5: "0xa3b1689Ab85409B15e07d2ED50A6EA9905074Ee5", // Goerli
  17000: "0xD4A7E1Bd8015057293f0D0A557088c286942e84b", // Holesky (testnet)
}

// Function to handle all deployments of core contracts using deployContract function
export async function deployAllContracts(
  signer: any,
  maxDataSize: BigNumber,
  verify: boolean = true
): Promise<Record<string, Contract>> {
  const isOnArb = await _isRunningOnArbitrum(signer)
  const chainId = signer.provider.network.chainId

  // If signer is on L1, deploy EigenDABlobVerifierL1 with EigenDAServiceManager as constructor argument
  // If signer is on L2, deploy EigenDABlobVerifierL2; blob verifier is used as eigenDARollupManager as part of rollup creation
  const eigenDARollupManager = (L1ServiceManagers.hasOwnProperty(chainId)) ? 
    await deployBlobVerifierL1('EigenDABlobVerifierL1', signer, [L1ServiceManagers[chainId as keyof typeof L1ServiceManagers]], verify) : await deployContract('EigenDABlobVerifierL2', signer, [], verify)

  const ethBridge = await deployContract('Bridge', signer, [], verify)
  const reader4844 = isOnArb
    ? ethers.constants.AddressZero
    : (await Toolkit4844.deployReader4844(signer)).address

  const ethSequencerInbox = await deployContract(
    'SequencerInbox',
    signer,
    [maxDataSize, reader4844, false],
    verify
  )

  const ethInbox = await deployContract('Inbox', signer, [maxDataSize], verify)
  const ethRollupEventInbox = await deployContract(
    'RollupEventInbox',
    signer,
    [],
    verify
  )
  const ethOutbox = await deployContract('Outbox', signer, [], verify)

  const erc20Bridge = await deployContract('ERC20Bridge', signer, [], verify)
  const erc20SequencerInbox = await deployContract(
    'SequencerInbox',
    signer,
    [maxDataSize, reader4844, true],
    verify
  )
  const erc20Inbox = await deployContract(
    'ERC20Inbox',
    signer,
    [maxDataSize],
    verify
  )
  const erc20RollupEventInbox = await deployContract(
    'ERC20RollupEventInbox',
    signer,
    [],
    verify
  )
  const erc20Outbox = await deployContract('ERC20Outbox', signer, [], verify)

  const bridgeCreator = await deployContract(
    'BridgeCreator',
    signer,
    [
      [
        ethBridge.address,
        ethSequencerInbox.address,
        ethInbox.address,
        ethRollupEventInbox.address,
        ethOutbox.address,
      ],
      [
        erc20Bridge.address,
        erc20SequencerInbox.address,
        erc20Inbox.address,
        erc20RollupEventInbox.address,
        erc20Outbox.address,
      ],
    ],
    verify
  )
  const prover0 = await deployContract('OneStepProver0', signer, [], verify)
  const proverMem = await deployContract(
    'OneStepProverMemory',
    signer,
    [],
    verify
  )
  const proverMath = await deployContract(
    'OneStepProverMath',
    signer,
    [],
    verify
  )
  const proverHostIo = await deployContract(
    'OneStepProverHostIo',
    signer,
    [],
    verify
  )
  const osp: Contract = await deployContract(
    'OneStepProofEntry',
    signer,
    [
      prover0.address,
      proverMem.address,
      proverMath.address,
      proverHostIo.address,
    ],
    verify
  )
  const challengeManager = await deployContract(
    'ChallengeManager',
    signer,
    [],
    verify
  )
  const rollupAdmin = await deployContract(
    'RollupAdminLogic',
    signer,
    [],
    verify
  )
  const rollupUser = await deployContract('RollupUserLogic', signer, [], verify)
  const upgradeExecutor = await deployUpgradeExecutor(signer)
  const validatorUtils = await deployContract(
    'ValidatorUtils',
    signer,
    [],
    verify
  )
  const validatorWalletCreator = await deployContract(
    'ValidatorWalletCreator',
    signer,
    [],
    verify
  )
  const rollupCreator = await deployContract(
    'RollupCreator',
    signer,
    [],
    verify
  )
  const deployHelper = await deployContract('DeployHelper', signer, [], verify)
  return {
    ethSequencerInbox,
    bridgeCreator,
    prover0,
    proverMem,
    proverMath,
    proverHostIo,
    osp,
    challengeManager,
    rollupAdmin,
    rollupUser,
    upgradeExecutor,
    validatorUtils,
    validatorWalletCreator,
    rollupCreator,
    deployHelper,
    eigenDARollupManager,
  }
}

export async function deployAndSetCacheManager(
  chainOwnerWallet: any,
  verify: boolean = true
) {
  const cacheManagerLogic = await deployContract(
    'CacheManager',
    chainOwnerWallet,
    [],
    verify
  )

  const proxyAdmin = await deployContract(
    'ProxyAdmin',
    chainOwnerWallet,
    [],
    verify
  )

  const cacheManagerProxy = await deployContract(
    'TransparentUpgradeableProxy',
    chainOwnerWallet,
    [cacheManagerLogic.address, proxyAdmin.address, '0x'],
    verify
  )

  const cacheManager = CacheManager__factory.connect(
    cacheManagerProxy.address,
    chainOwnerWallet
  )

  await (await cacheManager.initialize(INIT_CACHE_SIZE, INIT_DECAY)).wait()

  const arbOwner = ArbOwner__factory.connect(
    ARB_OWNER_ADDRESS,
    chainOwnerWallet
  )
  await (await arbOwner.addWasmCacheManager(cacheManagerProxy.address)).wait()

  return cacheManagerProxy
}

// Check if we're deploying to an Arbitrum chain
export async function _isRunningOnArbitrum(signer: any): Promise<boolean> {
  const arbSys = ArbSys__factory.connect(ARB_SYS_ADDRESS, signer)
  try {
    await arbSys.arbOSVersion()
    return true
  } catch (error) {
    return false
  }
}

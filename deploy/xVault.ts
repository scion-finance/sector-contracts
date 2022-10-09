import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function ({
  getNamedAccounts,
  deployments,
}: HardhatRuntimeEnvironment) {

  const { deployer, owner, guardian, manager, usdc } = await getNamedAccounts();
  const { deploy } = deployments;

  let USDC = usdc;
  if (!USDC) {
    const usdcMock = await deployments.get('USDCMock');
    USDC = usdcMock.address
  }

  const vault = await deploy('SectorCrossVault-0', {
    contract: 'SectorCrossVault',
    from: deployer,
    args: [USDC, 'PichaToken', 'PTK', owner, guardian, manager, owner, 0],
    skipIfAlreadyDeployed: false,
    log: true,
  });
  console.log('x-vault deplyed to', vault.address);
};

export default func;
func.tags = ['XVault'];
// Since USDC Mock is already setting the setup, we don't need to set it as a dependency
func.dependencies = ['USDCMock'];
module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy, execute } = deployments
  const { deployer } = await getNamedAccounts()

  const FACTORYS = [
    {
      factory: '0xb8c21e89983B5EcCD841846eA294c4c8a89718f1',
      initCodeHash: '0xa8ffca5939bbe6e18e96df724ec3b3539269b282d1be4a535d654f640a37dcf5',
    },
    {
      factory: '0x475c188B4e95612Aa2b1e327f2EA9639719151Ac',
      initCodeHash: '0xd5178f9f07b08d01d075cc5b7e1a1ae23a37b3811522cb2fed1367201d51d4e5',
    },
  ]

  const WETH9 = '0x1514000000000000000000000000000000000000'

  let quoterV3 = await deploy('QuoterV3', {
    admin: deployer,
    from: deployer,
    gasLimit: 8000000,
    args: [FACTORYS, WETH9],
    log: true,
  })
}

module.exports.tags = ['quoterV3']

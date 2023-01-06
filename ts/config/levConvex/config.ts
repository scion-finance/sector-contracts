export const addrs = {
  mainnet: {
    USDC: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    WETH: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    CRV: '0xD533a949740bb3306d119CC777fa900bA034cd52',
    CVX: '0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B',
    SNX: '0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F',
    UniswapV3Router: '0xE592427A0AEce92De3Edee1F18E0157C05861564',
    THREE_CRV: '0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490',
  },
};

export const levConvex = [
  {
    name: 'USDC-sUSD-levConvex',
    type: 'levConvex',
    curveAdapter: '0xbfB212e5D9F880bf93c47F3C32f6203fa4845222',
    convexRewardPool: '0xbEf6108D1F6B85c4c9AA3975e15904Bb3DFcA980',
    creditFacade: '0x61fbb350e39cc7bF22C01A469cf03085774184aa',
    convexBooster: '0xB548DaCb7e5d61BF47A026903904680564855B4E',
    coinId: 1, // curve token index
    underlying: addrs.mainnet.USDC,
    leverageFactor: 500,
    farmRouter: addrs.mainnet.UniswapV3Router,
    farmTokens: [addrs.mainnet.CRV, addrs.mainnet.CVX],
    chain: 'mainnet',
  },
  {
    name: 'USDC-FRAXUSDC-levConvex',
    type: 'levConvex',
    curveAdapter: '0xa4b2b3Dede9317fCbd9D78b8250ac44Bf23b64F4',
    convexRewardPool: '0x023e429Df8129F169f9756A4FBd885c18b05Ec2d',
    creditFacade: '0x61fbb350e39cc7bF22C01A469cf03085774184aa',
    convexBooster: '0xB548DaCb7e5d61BF47A026903904680564855B4E',
    coinId: 1, // curve token index
    underlying: addrs.mainnet.USDC,
    leverageFactor: 500,
    farmRouter: addrs.mainnet.UniswapV3Router,
    farmTokens: [addrs.mainnet.CRV, addrs.mainnet.CVX],
    chain: 'mainnet',
  },
  {
    name: 'USDC-gUSD-levConvex',
    type: 'levConvex',
    is3crv: true,
    curveAdapter: '0x6fA17Ffe020d72212A4DcA1560b27eA3cDAf965D',
    convexRewardPool: '0x3D4a70e5F355EAd0690213Ae9909f3Dc41236E3C',
    creditFacade: '0x61fbb350e39cc7bF22C01A469cf03085774184aa',
    convexBooster: '0xB548DaCb7e5d61BF47A026903904680564855B4E',
    underlying: addrs.mainnet.USDC,
    leverageFactor: 500,
    farmRouter: addrs.mainnet.UniswapV3Router,
    farmTokens: [addrs.mainnet.CRV, addrs.mainnet.CVX],
    chain: 'mainnet',
  },
  {
    name: 'USDC-lUSD-levConvex',
    type: 'levConvex',
    is3crv: true,
    curveAdapter: '0xD4c39a18338EA89B29965a8CAd28B7fb063c1429',
    convexRewardPool: '0xc34Ef7306B82f4e38E3fAB975034Ed0f76e0fdAA',
    creditFacade: '0x61fbb350e39cc7bF22C01A469cf03085774184aa',
    convexBooster: '0xB548DaCb7e5d61BF47A026903904680564855B4E',
    underlying: addrs.mainnet.USDC,
    leverageFactor: 500,
    farmRouter: addrs.mainnet.UniswapV3Router,
    farmTokens: [addrs.mainnet.CRV, addrs.mainnet.CVX],
    chain: 'mainnet',
  },
  {
    name: 'USDC-FRAX3CRV-levConvex',
    type: 'levConvex',
    is3crv: true,
    curveAdapter: '0x1C8281606377d79522515681BD94fc9d02b0d20B',
    convexRewardPool: '0xB26e063F062F76f9F7Dfa1a3f4b7fDa4A2197DfB',
    creditFacade: '0x61fbb350e39cc7bF22C01A469cf03085774184aa',
    convexBooster: '0xB548DaCb7e5d61BF47A026903904680564855B4E',
    underlying: addrs.mainnet.USDC,
    leverageFactor: 500,
    farmRouter: addrs.mainnet.UniswapV3Router,
    farmTokens: [addrs.mainnet.CRV, addrs.mainnet.CVX],
    chain: 'mainnet',
  },
];
export default {
  Address: {
    Usdc: {
      mainnet: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      arbitrum: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
      arbitrum_sepolia: "0xdafcF0d6fc4a43cf8595f2172c07CEa7f273531D",
      sepolia: "0xaa8e23fb1079ea71e0a56f48a2aa51851d8433d0",
      goerli: "0xc87095a378DEb619BA55Fff67f40fC1e7C0b219C",
      // blast_sepolia: "0x4200000000000000000000000000000000000022", // blast USDB
      blast_sepolia: "0x9C75DA71284E9F912C9237253F21f90223D7034a", // stvol vUSDB
      base_sepolia: "0xe722424e913f48bAC7CD2C1Ae981e2cD09bd95EC", // stvol vUSDC
      base: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", // USDC
    },
    Oracle: {
      mainnet: "0x4305FB66699C3B2702D4d05CF36551390A4c69C6",
      goerli: "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C", // PythContractAddress
      arbitrum: "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C",
      arbitrum_sepolia: "0x4374e5a8b9c22271e9eb878a2aa31de97df15daf",
      sepolia: "0xDd24F84d36BF92C65F92307595335bdFab5Bbd21",
      blast: "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729",
      blast_sepolia: "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729",
      base_sepolia: "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729",
      base: "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a",
    },
    Admin: {
      mainnet: "0x93072915E6fD257Ca98eD80343D6fbc8e2426C9F",
      arbitrum: "0xB897F50F117B983CFa42bd2a6aB77f8bE9967324",
      arbitrum_sepolia: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      sepolia: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      goerli: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      blast: "0x194A9f93072C38C91c9784edd8C7AC8Bc76bca53",
      blast_sepolia: "0x194A9f93072C38C91c9784edd8C7AC8Bc76bca53",
      base_sepolia: "0x26B85826014fF3483CBC550B3DDAF5954cc15d70",
      base: "0x26B85826014fF3483CBC550B3DDAF5954cc15d70",
    },
    Operator: {
      mainnet: "0x5e6c12e083B1Ad5fB7c7bf5582467EB74cD58a66",
      arbitrum: "0xaAA3D934271dcbDE1D405cac6c20D3edC719b1A2", // 0x5e6c12e083B1Ad5fB7c7bf5582467EB74cD58a66(ETH), 0xaAA3D934271dcbDE1D405cac6c20D3edC719b1A2(BTC)
      arbitrum_sepolia: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      sepolia: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      goerli: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      blast: "0x194A9f93072C38C91c9784edd8C7AC8Bc76bca53",
      blast_sepolia: "0x194A9f93072C38C91c9784edd8C7AC8Bc76bca53",
      base_sepolia: "0x02F5BC2D279D2Ff10CACa13e04D80587824951C8",
      base: "0x02F5BC2D279D2Ff10CACa13e04D80587824951C8",
    },
    OperatorVault: {
      mainnet: "0xFb6B24942a19F138EF468EC39Ce8653A87500832",
      arbitrum: "0x7571F9e1a48f59ffC55cDaA3709e8B76Fab71acd",
      arbitrum_sepolia: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      sepolia: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      goerli: "0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0",
      blast: "0x194A9f93072C38C91c9784edd8C7AC8Bc76bca53",
      blast_sepolia: "0x194A9f93072C38C91c9784edd8C7AC8Bc76bca53",
      base_sepolia: "0xfc48F475E7296c9e645311B85F8F2bcb64BD8fbd",
      base: "0xfc48F475E7296c9e645311B85F8F2bcb64BD8fbd",
    },
  },
  PythPriceId: {
    mainnet: {
      BTC_USD: "0xc96458d393fe9deb7a7d63a0ac41e2898a67a7750dbd166673279e06c868df0a",
      ETH_USD: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
    },
    goerli: {
      BTC_USD: "0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b",
      ETH_USD: "0xca80ba6dc32e08d06f1aa886011eed1d77c77be9eb761cc10d72b7d0a2fd57a6",
    },
    arbitrum: {
      BTC_USD: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
      ETH_USD: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
    },
    sepolia: {
      BTC_USD: "0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b",
      ETH_USD: "0xca80ba6dc32e08d06f1aa886011eed1d77c77be9eb761cc10d72b7d0a2fd57a6",
    },
    arbitrum_sepolia: {
      BTC_USD: "0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b",
      ETH_USD: "0xca80ba6dc32e08d06f1aa886011eed1d77c77be9eb761cc10d72b7d0a2fd57a6",
    },
    blast_sepolia: {
      BTC_USD: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
      ETH_USD: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
      WIF_USD: "0x4ca4beeca86f0d164160323817a4e42b10010a724c2217c6ee41b54cd4cc61fc",
    },
  },
  CommissionFee: {
    mainnet: 200, // 2%
    goerli: 200, // 2%
    arbitrum: 200, // 2%
    sepolia: 200, // 2%
    arbitrum_sepolia: 200, // 2%
    arbitrum_goerli: 200, // 2%
    blast: 200, // 2%
    blast_sepolia: 200, // 2%
    base_sepolia: 200, // 2%
    base: 200, // 2%
  },
};

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "@uniswap/v3-core/contracts/libraries/SafeCast.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import "../interfaces/IQuoterV3.sol";
import "../libraries/Path.sol";

/// @title Provides quotes for swaps
/// @notice Allows getting the expected amount out or amount in for a given swap without executing the swap
/// @dev These functions are not gas efficient and should _not_ be called on chain. Instead, optimistically execute
/// the swap and check the amounts in the callback.
contract QuoterV3 is IQuoterV3, IUniswapV3SwapCallback {
    using Path for bytes;
    using SafeCast for uint256;

    /// @notice The identifying key of the pool
    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    struct FactoryData {
        address factory;
        bytes32 initCodeHash;
    }

    /// @dev Transient storage variable used to check a safety condition in exact output swaps.
    uint256 private amountOutCached;

    // We have multiple factory addresses to support different DEXes
    address[] public factories;
    address public WETH9;

    // All pool init code hashes of each factory
    mapping(address => bytes32) public poolInitCodeHashes;

    constructor(FactoryData[] memory _factorys, address _WETH9) {
        for (uint256 i = 0; i < _factorys.length; i++) {
            factories.push(_factorys[i].factory);
            poolInitCodeHashes[_factorys[i].factory] = _factorys[i].initCodeHash;
        }
        WETH9 = _WETH9;
    }

    function getPools(address tokenA, address tokenB, uint24 fee) private view returns (IUniswapV3Pool[] memory) {
        IUniswapV3Pool[] memory pools = new IUniswapV3Pool[](factories.length);
        for (uint256 i = 0; i < factories.length; i++) {
            pools[i] = IUniswapV3Pool(_computeAddress(factories[i], _getPoolKey(tokenA, tokenB, fee)));
        }
        return pools;
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory path)
        external
        view
        override
    {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();
        _verifyCallback(tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountToPay, uint256 amountReceived) = amount0Delta > 0
            ? (tokenIn < tokenOut, uint256(amount0Delta), uint256(-amount1Delta))
            : (tokenOut < tokenIn, uint256(amount1Delta), uint256(-amount0Delta));
        if (isExactInput) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountReceived)
                revert(ptr, 32)
            }
        } else {
            // if the cache has been populated, ensure that the full output amount has been received
            if (amountOutCached != 0) require(amountReceived == amountOutCached);
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountToPay)
                revert(ptr, 32)
            }
        }
    }

    /// @dev Parses a revert reason that should contain the numeric quote
    function parseRevertReason(bytes memory reason) private pure returns (uint256) {
        if (reason.length != 32) {
            if (reason.length < 68) revert("Unexpected error");
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (uint256));
    }

    /// @inheritdoc IQuoterV3
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) public override returns (uint256 amountOut, address pool) {
        bool zeroForOne = tokenIn < tokenOut;

        IUniswapV3Pool[] memory pools = getPools(tokenIn, tokenOut, fee);

        // init with ZERO
        amountOut = 0;
        pool = address(0);

        for (uint256 i = 0; i < pools.length; i++) {
            bytes memory swapData = _encodeSwapData(tokenIn, fee, tokenOut);
            try pools[i].swap(
                address(this), // address(0) might cause issues with some tokens
                zeroForOne,
                amountIn.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                swapData
            ) {} catch (bytes memory reason) {
                uint256 returnValue = parseRevertReason(reason);

                // we will take the maximum of all return values
                if (amountOut < returnValue) {
                    amountOut = returnValue;
                    pool = address(pools[i]);
                }
            }
        }
    }

    /// @inheritdoc IQuoterV3
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        override
        returns (uint256 amountOut, address[] memory pools)
    {
        pools = new address[](path.numPools());
        uint256 i = 0;
        while (true) {
            bool hasMultiplePools = path.hasMultiplePools();

            (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();

            // the outputs of prior swaps become the inputs to subsequent ones
            (amountIn, pools[i]) = quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);

            // decide whether to continue or terminate
            if (hasMultiplePools) {
                path = path.skipToken();
            } else {
                return (amountIn, pools);
            }
        }
    }

    /// @inheritdoc IQuoterV3
    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) public override returns (uint256 amountIn, address pool) {
        bool zeroForOne = tokenIn < tokenOut;

        IUniswapV3Pool[] memory pools = getPools(tokenIn, tokenOut, fee);

        // init with MAX_INT
        amountIn = uint256(-1);
        pool = address(0);

        for (uint256 i = 0; i < pools.length; i++) {
            // if no price limit has been specified, cache the output amount for comparison in the swap callback
            if (sqrtPriceLimitX96 == 0) amountOutCached = amountOut;
            bytes memory swapData = _encodeSwapData(tokenOut, fee, tokenIn);
            try pools[i].swap(
                address(this), // address(0) might cause issues with some tokens
                zeroForOne,
                -amountOut.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                swapData
            ) {} catch (bytes memory reason) {
                if (sqrtPriceLimitX96 == 0) delete amountOutCached; // clear cache

                uint256 returnValue = parseRevertReason(reason);

                // we will take the minimum of all return values
                if (amountIn > returnValue) {
                    amountIn = returnValue;
                    pool = address(pools[i]);
                }
            }
        }
    }

    /// @inheritdoc IQuoterV3
    function quoteExactOutput(bytes memory path, uint256 amountOut)
        external
        override
        returns (uint256 amountIn, address[] memory pools)
    {
        pools = new address[](path.numPools());
        uint256 i = 0;
        while (true) {
            bool hasMultiplePools = path.hasMultiplePools();

            (address tokenOut, address tokenIn, uint24 fee) = path.decodeFirstPool();

            // the inputs of prior swaps become the outputs of subsequent ones
            (amountOut, pools[i]) = quoteExactOutputSingle(tokenIn, tokenOut, fee, amountOut, 0);

            // decide whether to continue or terminate
            if (hasMultiplePools) {
                path = path.skipToken();
            } else {
                return (amountOut, pools);
            }
        }
    }

    function _encodeSwapData(address tokenOne, uint24 fee, address tokenTwo) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenOne, fee, tokenTwo);
    }

    /// @notice Returns the address of a valid Uniswap V3 Pool
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @return pool The V3 pool contract address
    function _verifyCallback(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool pool) {
        for (uint256 i = 0; i < factories.length; i++) {
            pool = IUniswapV3Pool(_computeAddress(factories[i], _getPoolKey(tokenA, tokenB, fee)));
            if (msg.sender == address(pool)) return pool;
        }
        revert("Invalid pool");
    }

    /// @notice Returns PoolKey: the ordered tokens with the matched fee levels
    /// @param tokenA The first token of a pool, unsorted
    /// @param tokenB The second token of a pool, unsorted
    /// @param fee The fee level of the pool
    /// @return Poolkey The pool details with ordered token0 and token1 assignments
    function _getPoolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, fee: fee});
    }

    /// @notice Deterministically computes the pool address given the factory and PoolKey
    /// @param factory The Uniswap V3 factory contract address
    /// @param key The PoolKey
    /// @return pool The contract address of the V3 pool
    function _computeAddress(address factory, PoolKey memory key) internal view returns (address pool) {
        require(key.token0 < key.token1);
        pool = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff",
                        factory,
                        keccak256(abi.encode(key.token0, key.token1, key.fee)),
                        poolInitCodeHashes[factory]
                    )
                )
            )
        );
    }
}

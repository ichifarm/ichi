pragma solidity ^0.6.0;

import "./lib/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// oneFactor is a lookup table
// you can input a number and get back a list of all it's factors
contract oneFactor {
    using SafeMath for uint256;

    mapping (uint256 => uint256[]) private _factorLookup;
    uint256 public constant DECIMALS = 10 ** 9;

    function getFactorList(uint256 key)
        public
        view
        returns (uint256[] memory)
    {
        return _factorLookup[key];
    }

    // calculates factors for [startingKey, endingKey)
    function populateFactors(uint256 startingKey, uint256 endingKey)
        public
    {
        require(startingKey < endingKey, "ending key must be greater than starting key");

        for (uint256 i = startingKey; i < endingKey; i++) {
            calculateFactor(i);
        }
    }

    // function called by populate factors
    function calculateFactor(uint256 number)
        internal
    {
        // only continue if empty
        if (_factorLookup[number].length == 0) {
            for (uint256 i = 1; i <= Math.sqrt(number); i++) {
                if (number % i == 0) {
                    _factorLookup[number].push(i);

                    if (i * DECIMALS != Math.sqrt(number * DECIMALS) && number.div(i) != i) {
                        _factorLookup[number].push(number.div(i));
                    }
                }
            }
        }
    }
}

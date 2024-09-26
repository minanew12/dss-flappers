// SPDX-FileCopyrightText: © 2023 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";

import { DssInstance, MCD } from "dss-test/MCD.sol";
import { FlapperDeploy } from "deploy/FlapperDeploy.sol";
import { FlapperUniV2Config, FlapperInit } from "deploy/FlapperInit.sol";
import { FlapperUniV2SwapOnly } from "src/FlapperUniV2SwapOnly.sol";
import { SplitterMock } from "test/mocks/SplitterMock.sol";
import { MedianizerMock } from "test/mocks/MedianizerMock.sol";
import "./helpers/UniswapV2Library.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface VatLike {
    function sin(address) external view returns (uint256);
    function dai(address) external view returns (uint256);
}

interface VowLike {
    function file(bytes32, address) external;
    function file(bytes32, uint256) external;
    function flap() external returns (uint256);
    function Sin() external view returns (uint256);
    function Ash() external view returns (uint256);
    function heal(uint256) external;
    function bump() external view returns (uint256);
    function hump() external view returns (uint256);
}

interface SpotterLike {
    function par() external view returns (uint256);
}

interface PairLike {
    function mint(address) external returns (uint256);
    function sync() external;
}

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface UniV2FactoryLike {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

contract FlapperUniV2SwapOnlyTest is DssTest {
    using stdStorage for StdStorage;

    SplitterMock         public splitter;
    FlapperUniV2SwapOnly public flapper;
    FlapperUniV2SwapOnly public imxFlapper;
    MedianizerMock       public medianizer;
    MedianizerMock       public imxMedianizer;

    address     USDS_JOIN;
    address     SPOT;
    address     USDS;
    address     SKY;
    address     USDC;
    address     PAUSE_PROXY;
    VatLike     vat;
    VowLike     vow;
    address     UNIV2_USDS_IMX_PAIR;

    address constant LOG                 = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    address constant IMX                 = 0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF; // Random token that orders after USDS
    address constant UNIV2_FACTORY       = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNIV2_SKY_USDS_PAIR = 0x2621CC0B3F3c079c1Db0E80794AA24976F0b9e3c;

    event Exec(uint256 lot, uint256 bought);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        USDS_JOIN     = ChainlogLike(LOG).getAddress("USDS_JOIN");
        SPOT          = ChainlogLike(LOG).getAddress("MCD_SPOT");
        USDS          = ChainlogLike(LOG).getAddress("USDS");
        SKY           = ChainlogLike(LOG).getAddress("SKY");
        USDC          = ChainlogLike(LOG).getAddress("USDC");
        PAUSE_PROXY   = ChainlogLike(LOG).getAddress("MCD_PAUSE_PROXY");
        vat           = VatLike(ChainlogLike(LOG).getAddress("MCD_VAT"));
        vow           = VowLike(ChainlogLike(LOG).getAddress("MCD_VOW"));

        UNIV2_USDS_IMX_PAIR = UniV2FactoryLike(UNIV2_FACTORY).getPair(USDS, IMX);
        if (UNIV2_USDS_IMX_PAIR == address(0)) {
            UNIV2_USDS_IMX_PAIR = UniV2FactoryLike(UNIV2_FACTORY).createPair(USDS, IMX);
        }

        splitter = new SplitterMock(USDS_JOIN);
        vm.startPrank(PAUSE_PROXY);
        vow.file("hump", 50_000_000 * RAD);
        vow.file("bump", 5707 * RAD);
        vow.file("flapper", address(splitter));
        vm.stopPrank();

        {
            deal(IMX, UNIV2_USDS_IMX_PAIR, 200_000_0000 * WAD, true);
            deal(USDS, UNIV2_USDS_IMX_PAIR, 10_000_0000 * WAD, true);
            PairLike(UNIV2_USDS_IMX_PAIR).sync();
        }

        (flapper, medianizer) = setUpFlapper(SKY, UNIV2_SKY_USDS_PAIR, 0.06 * 1e18, "MCD_FLAP") ;
        assertEq(flapper.usdsFirst(), false);

        (imxFlapper, imxMedianizer) = setUpFlapper(IMX, UNIV2_USDS_IMX_PAIR, 1.85 * 1e18, bytes32(0));
        assertEq(imxFlapper.usdsFirst(), true);

        changeFlapper(address(flapper)); // Use SKY flapper by default

        // Create additional surplus if needed
        uint256 bumps = 2 * vow.bump(); // two kicks
        if (vat.dai(address(vow)) < vat.sin(address(vow)) + bumps + vow.hump()) {
            stdstore.target(address(vat)).sig("dai(address)").with_key(address(vow)).depth(0).checked_write(
                vat.sin(address(vow)) + bumps + vow.hump()
            );
        }

        // Heal if needed
        if (vat.sin(address(vow)) > vow.Sin() + vow.Ash()) {
            vow.heal(vat.sin(address(vow)) - vow.Sin() - vow.Ash());
        }
    }

    function setUpFlapper(address gem, address pair, uint256 price, bytes32 prevChainlogKey)
        internal
        returns (FlapperUniV2SwapOnly _flapper, MedianizerMock _medianizer)
    {
        _medianizer = new MedianizerMock();
        _medianizer.kiss(address(this));

        _flapper = FlapperUniV2SwapOnly(FlapperDeploy.deployFlapperUniV2({
            deployer: address(this),
            owner:    PAUSE_PROXY,
            spotter:  SPOT,
            usds:     USDS,
            gem:      gem,
            pair:     pair,
            receiver: PAUSE_PROXY,
            swapOnly: true
        }));

        // Note - this part emulates the spell initialization
        vm.startPrank(PAUSE_PROXY);
        FlapperUniV2Config memory cfg = FlapperUniV2Config({
            want:            WAD * 97 / 100,
            pip:             address(_medianizer),
            pair:            pair,
            usds:            USDS,
            splitter:        address(splitter),
            prevChainlogKey: prevChainlogKey,
            chainlogKey:     "MCD_FLAP_BURN"
        });
        DssInstance memory dss = MCD.loadFromChainlog(LOG);
        FlapperInit.initFlapperUniV2(dss, address(_flapper), cfg);
        FlapperInit.initDirectOracle(address(_flapper));
        vm.stopPrank();

        assertEq(dss.chainlog.getAddress("MCD_FLAP_BURN"), address(_flapper));

        // Add initial liquidity if needed
        (uint256 reserveUsds, ) = UniswapV2Library.getReserves(UNIV2_FACTORY, USDS, gem);
        uint256 minimalUsdsReserve = 280_000 * WAD;
        if (reserveUsds < minimalUsdsReserve) {
            _medianizer.setPrice(price);
            changeUniV2Price(price, gem, pair);
            (reserveUsds, ) = UniswapV2Library.getReserves(UNIV2_FACTORY, USDS, gem);
            if (reserveUsds < minimalUsdsReserve) {
                topUpLiquidity(minimalUsdsReserve - reserveUsds, gem, pair);
            }
        } else {
            // If there is initial liquidity, then the oracle price should be set to the current price
            _medianizer.setPrice(uniV2UsdsForGem(WAD, gem));
        }
    }

    function changeFlapper(address _flapper) internal {
        vm.prank(PAUSE_PROXY); splitter.file("flapper", address(_flapper));
    }

    function refAmountOut(uint256 amountIn, address pip) internal view returns (uint256) {
        return amountIn * WAD / (uint256(MedianizerMock(pip).read()) * RAY / SpotterLike(SPOT).par());
    }

    function uniV2GemForUsds(uint256 amountIn, address gem) internal view returns (uint256 amountOut) {
        (uint256 reserveUsds, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, USDS, gem);
        amountOut = UniswapV2Library.getAmountOut(amountIn, reserveUsds, reserveGem);
    }

    function uniV2UsdsForGem(uint256 amountIn, address gem) internal view returns (uint256 amountOut) {
        (uint256 reserveUsds, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, USDS, gem);
        return UniswapV2Library.getAmountOut(amountIn, reserveGem, reserveUsds);
    }

    function changeUniV2Price(uint256 usdsForGem, address gem, address pair) internal {
        (uint256 reserveUsds, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, USDS, gem);
        uint256 currentUsdsForGem = reserveUsds * WAD / reserveGem;

        // neededReserveUsds * WAD / neededReserveSky = usdsForGem;
        if (currentUsdsForGem > usdsForGem) {
            deal(gem, pair, reserveUsds * WAD / usdsForGem);
        } else {
            deal(USDS, pair, reserveGem * usdsForGem / WAD);
        }
        PairLike(pair).sync();
    }

    function topUpLiquidity(uint256 usdsAmt, address gem, address pair) internal {
        (uint256 reserveUsds, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, USDS, gem);
        uint256 gemAmt = UniswapV2Library.quote(usdsAmt, reserveUsds, reserveGem);

        deal(USDS, address(this), GemLike(USDS).balanceOf(address(this)) + usdsAmt);
        deal(gem, address(this), GemLike(gem).balanceOf(address(this)) + gemAmt);

        GemLike(USDS).transfer(pair, usdsAmt);
        GemLike(gem).transfer(pair, gemAmt);
        uint256 liquidity = PairLike(pair).mint(address(this));
        assertGt(liquidity, 0);
        assertGe(GemLike(pair).balanceOf(address(this)), liquidity);
    }

    function marginalWant(address gem, address pip) internal view returns (uint256) {
        uint256 wbump = vow.bump() / RAY;
        uint256 actual = uniV2GemForUsds(wbump, gem);
        uint256 ref    = refAmountOut(wbump, pip);
        return actual * WAD / ref;
    }

    function doExec(address _flapper, address gem, address pair) internal {
        uint256 initialGem = GemLike(gem).balanceOf(address(PAUSE_PROXY));
        uint256 initialDaiVow = vat.dai(address(vow));
        uint256 initialReserveUsds = GemLike(USDS).balanceOf(pair);
        uint256 initialReserveSky = GemLike(gem).balanceOf(pair);

        vm.expectEmit(false, false, false, false); // only check event signature (topic 0)
        emit Exec(0, 0);
        vow.flap();

        assertGt(GemLike(gem).balanceOf(address(PAUSE_PROXY)), initialGem);
        assertGt(GemLike(USDS).balanceOf(pair), initialReserveUsds);
        assertLt(GemLike(gem).balanceOf(pair), initialReserveSky);
        assertEq(initialDaiVow - vat.dai(address(vow)), vow.bump());
        assertEq(GemLike(USDS).balanceOf(address(_flapper)), 0);
        assertEq(GemLike(gem).balanceOf(address(_flapper)), 0);
    }

    function testDefaultValues() public {
        FlapperUniV2SwapOnly f = new FlapperUniV2SwapOnly(USDS_JOIN, SPOT, SKY, UNIV2_SKY_USDS_PAIR, PAUSE_PROXY);
        assertEq(f.want(), WAD);
        assertEq(f.wards(address(this)), 1);
    }

    function testIllegalGemDecimals() public {
        vm.expectRevert("FlapperUniV2SwapOnly/gem-decimals-not-18");
        flapper = new FlapperUniV2SwapOnly(USDS_JOIN, SPOT, USDC, UNIV2_SKY_USDS_PAIR, PAUSE_PROXY);
    }

    function testAuth() public {
        checkAuth(address(flapper), "FlapperUniV2SwapOnly");
    }

    function testAuthModifiers() public virtual {
        assert(flapper.wards(address(this)) == 0);

        checkModifier(address(flapper), string(abi.encodePacked("FlapperUniV2SwapOnly", "/not-authorized")), [
            FlapperUniV2SwapOnly.exec.selector
        ]);
    }

    function testFileUint() public {
        checkFileUint(address(flapper), "FlapperUniV2SwapOnly", ["want"]);
    }

    function testFileAddress() public {
        checkFileAddress(address(flapper), "FlapperUniV2SwapOnly", ["pip"]);
    }

    function testExec() public {
        doExec(address(flapper), SKY, UNIV2_SKY_USDS_PAIR);
    }

    function testExecUsdsFirst() public {
        changeFlapper(address(imxFlapper));
        doExec(address(imxFlapper), IMX, UNIV2_USDS_IMX_PAIR);
    }

    function testExecWantAllows() public {
        uint256 _marginalWant = marginalWant(SKY, address(medianizer));
        vm.prank(PAUSE_PROXY); flapper.file("want", _marginalWant * 99 / 100);
        doExec(address(flapper), SKY, UNIV2_SKY_USDS_PAIR);
    }

    function testExecWantBlocks() public {
        uint256 _marginalWant = marginalWant(SKY, address(medianizer));
        vm.prank(PAUSE_PROXY); flapper.file("want", _marginalWant * 101 / 100);
        vm.expectRevert("FlapperUniV2SwapOnly/insufficient-buy-amount");
        vow.flap();
    }

    function testExecUsdsFirstWantBlocks() public {
        changeFlapper(address(imxFlapper));
        uint256 _marginalWant = marginalWant(IMX, address(imxMedianizer));
        vm.prank(PAUSE_PROXY); imxFlapper.file("want", _marginalWant * 101 / 100);
        vm.expectRevert("FlapperUniV2SwapOnly/insufficient-buy-amount");
        vow.flap();
    }

    function testExecDonationUsds() public {
        deal(USDS, UNIV2_SKY_USDS_PAIR, GemLike(USDS).balanceOf(UNIV2_SKY_USDS_PAIR) * 1005 / 1000);
        // This will now sync the reserves before the swap
        doExec(address(flapper), SKY, UNIV2_SKY_USDS_PAIR);
    }

    function testExecDonationGem() public {
        deal(SKY, UNIV2_SKY_USDS_PAIR, GemLike(SKY).balanceOf(UNIV2_SKY_USDS_PAIR) * 1005 / 1000);
        // This will now sync the reserves before the swap
        doExec(address(flapper), SKY, UNIV2_SKY_USDS_PAIR);
    }
}

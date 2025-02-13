//
//  IIgsMemoryMapTests.mm
//  Clock SignalTests
//
//  Created by Thomas Harte on 25/10/2020.
//  Copyright © 2020 Thomas Harte. All rights reserved.
//

#import <XCTest/XCTest.h>

#include "../../../Machines/Apple/AppleIIgs/MemoryMap.hpp"

namespace {
	using MemoryMap = Apple::IIgs::MemoryMap;
}

@interface IIgsMemoryMapTests : XCTestCase
@end

@implementation IIgsMemoryMapTests {
	MemoryMap _memoryMap;
	std::vector<uint8_t> _ram;
	std::vector<uint8_t> _rom;
}

- (void)setUp {
	_ram.resize((128 + 8 * 1024) * 1024);
	_rom.resize(256 * 1024);
	_memoryMap.set_storage(_ram, _rom);

	// If this isn't the first test run, RAM and ROM may have old values.
	// Initialise to a known state.
	memset(_ram.data(), 0, _ram.size());
	memset(_rom.data(), 0, _rom.size());
}

- (void)write:(uint8_t)value address:(uint32_t)address {
	const auto &region = MemoryMapRegion(_memoryMap, address);
	XCTAssertFalse(region.flags & MemoryMap::Region::IsIO);
	MemoryMapWrite(_memoryMap, region, address, &value);
}

- (uint8_t)readAddress:(uint32_t)address {
	const auto &region = MemoryMapRegion(_memoryMap, address);
	uint8_t value;
	MemoryMapRead(region, address, &value);
	return value;
}

- (void)testAllRAM {
	// Disable IO/LC 'shadowing', to give linear memory up to bank $80.
	_memoryMap.set_shadow_register(0x5f);

	// Fill memory via the map.
	for(int address = 0x00'0000; address < 0x80'0000; ++address) {
		const uint8_t value = uint8_t(address ^ (address >> 8) ^ (address >> 16));
		[self write:value address:address];
	}

	// Test by direct access.
	for(int address = 0x00'0000; address < 0x80'0000; ++address) {
		const uint8_t value = uint8_t(address ^ (address >> 8) ^ (address >> 16));
		XCTAssertEqual([self readAddress:address], value);
	}
}

- (void)testROMIsReadonly {
	_rom[0] = 0xc0;

	// Test that ROM can be read in the correct location.
	XCTAssertEqual([self readAddress:0xfc'0000], 0xc0);

	// Try writing to it, and check that nothing happened.
	[self write:0xfc address:0xfc'0000];
	XCTAssertEqual(_rom[0], 0xc0);
}

/// Tests that the same portion of ROM is visible in banks $00, $01, $e0 and $e1.
- (void)testROMVisibility {
	_rom.back() = 0xa8;
	auto test_bank = [self](uint32_t bank) {
		const uint32_t address = bank | 0xffff;
		XCTAssertEqual([self readAddress:address], 0xa8);
	};

	test_bank(0x00'0000);
	test_bank(0x01'0000);
	test_bank(0xe0'0000);
	test_bank(0xe1'0000);
}

/// Tests that writes to $00:$0400 and to $01:$0400 are subsequently visible at $e0:$0400 and $e1:$0400.
- (void)testShadowing {
	[self write:0xab address:0x00'0400];
	[self write:0xcd address:0x01'0400];
	XCTAssertEqual([self readAddress:0xe0'0400], 0xab);
	XCTAssertEqual([self readAddress:0xe1'0400], 0xcd);
}

/// Tests that a write to bank $00 which via the auxiliary switches is redirected to bank $01 is then
/// mirrored to $e1.
- (void)testAuxiliaryShadowing {
	// Select the alternate text page 1.
	_memoryMap.access(0xc001, false);	// Set 80STORE.
	_memoryMap.access(0xc055, false);	// Set PAGE2.
										// These two things together should enable auxiliary memory for text page 1.
										// No, really.

	// Enable shadowing of text page 1.
	_memoryMap.set_shadow_register(0x00);

	// Establish a different value in bank $e1, then write
	// to bank $00 and check banks $01 and $e1.
	[self write: 0xcb address:0xe1'0400];
	[self write: 0xde address:0x00'0400];

	XCTAssertEqual([self readAddress:0xe1'0400], 0xde);
	XCTAssertEqual([self readAddress:0x01'0400], 0xde);

	// Reset the $e1 page version and check all three detinations.
	[self write: 0xcb address:0xe1'0400];

	XCTAssertEqual([self readAddress:0xe1'0400], 0xcb);
	XCTAssertEqual([self readAddress:0x00'0400], 0xde);
	XCTAssertEqual([self readAddress:0x01'0400], 0xde);
}

- (void)testE0E1RAMConsistent {
	// Do some random language card paging, to hit set_language_card.
	_memoryMap.set_state_register(0x00);
	_memoryMap.set_state_register(0xff);

	[self write: 0x12 address:0xe0'0000];
	[self write: 0x34 address:0xe1'0000];

	XCTAssertEqual(_ram[_ram.size() - 128*1024], 0x12);
	XCTAssertEqual(_ram[_ram.size() - 64*1024], 0x34);
}

- (void)testAuxiliarySwitches {
	// Inhibit IO/LC 'shadowing'.
	_memoryMap.set_shadow_register(0x40);

	// Check that all writes and reads currently occur to main RAM.
	XCTAssertEqual(_memoryMap.get_state_register() & 0xf0, 0x00);
	for(int c = 0; c < 65536; c++) {
		const uint8_t value = c ^ (c >> 8);
		[self write:value address:c];
		XCTAssertEqual(_ram[c], value);
	}
	
	// Reset.
	memset(_ram.data(), 0, 128*1024);

	// Set writing to auxiliary memory.
	// Reading should still be from main.
	_memoryMap.access(0xc005, false);
	XCTAssertEqual(_memoryMap.get_state_register() & 0xf0, 0x10);
	for(int c = 0x0200; c < 0xc000; c++) {
		const uint8_t value = c ^ (c >> 8);
		[self write:value address:c];
		XCTAssertEqual(_ram[c + 64*1024], value);
		XCTAssertEqual([self readAddress:c], 0);
	}

	// Reset.
	memset(_ram.data(), 0, 128*1024);

	// Switch reading and writing.
	_memoryMap.access(0xc004, false);
	_memoryMap.access(0xc003, false);
	XCTAssertEqual(_memoryMap.get_state_register() & 0xf0, 0x20);
	for(int c = 0x0200; c < 0xc000; c++) {
		const uint8_t value = c ^ (c >> 8);
		[self write:value address:c];
		XCTAssertEqual(_ram[c], value);
		XCTAssertEqual([self readAddress:c], 0);
	}

	// Reset.
	memset(_ram.data(), 0, 128*1024);

	// Test main zero page.
	for(int c = 0x0000; c < 0x0200; c++) {
		const uint8_t value = c ^ (c >> 8);
		[self write:value address:c];
		XCTAssertEqual(_ram[c], value);
		XCTAssertEqual([self readAddress:c], value);
	}

	// Reset.
	memset(_ram.data(), 0, 128*1024);

	// Enable the alternate zero page.
	_memoryMap.access(0xc009, false);
	XCTAssertEqual(_memoryMap.get_state_register() & 0xf0, 0xa0);
	for(int c = 0x0000; c < 0x0200; c++) {
		const uint8_t value = c ^ (c >> 8);
		[self write:value address:c];
		XCTAssertEqual(_ram[c + 64*1024], value);
		XCTAssertEqual([self readAddress:c], value);
	}

	// Reset.
	memset(_ram.data(), 0, 128*1024);

	// Enable 80STORE and PAGE2 and test for access to the second video page.
	_memoryMap.access(0xc001, false);
	_memoryMap.access(0xc055, true);
	XCTAssertEqual(_memoryMap.get_state_register() & 0xf0, 0xe0);
	for(int c = 0x0400; c < 0x0800; c++) {
		const uint8_t value = c ^ (c >> 8);
		[self write:value address:c];
		XCTAssertEqual(_ram[c + 64*1024], value);
		XCTAssertEqual([self readAddress:c], value);
	}

	// Reset.
	memset(_ram.data(), 0, 128*1024);

	// Enable HIRES and test for access to the second video page.
	_memoryMap.access(0xc057, true);
	for(int c = 0x2000; c < 0x4000; c++) {
		const uint8_t value = c ^ (c >> 8);
		[self write:value address:c];
		XCTAssertEqual(_ram[c + 64*1024], value);
		XCTAssertEqual([self readAddress:c], value);
	}
}

@end


class TilemapChanges {
  array<int32> state(0x1000); // 0x1000 * 16-bit items (using int32 to allow -1 to mean "no change")
  int size = 0;
  bool serialized = false;

  int32 get_opIndex(int idx) property {
    return state[idx];
  }
  void set_opIndex(int idx, int32 value) property {
    state[idx] = value;
    serialized = false;
  }

  void reset(uint8 size) {
    // only 0x20 or 0x40 are acceptable values:
    if (size <= 0x20) size = 0x20;
    else size = 0x40;

    //message("tilemap.reset(0x" + fmtHex(size, 2) + ")");
    this.size = size;
    serialized = false;

    for (uint i = 0; i < 0x1000; i++) {
      state[i] = -1;
    }
  }

  // convert overworld tilemap address to VRAM address:
  uint16 ow_tilemap_to_vram_address(uint16 addr) {
    uint16 vaddr = 0;

    if ((addr & 0x003F) >= 0x0020) {
      vaddr = 0x0400;
    }

    if ((addr & 0x0FFF) >= 0x0800) {
      vaddr += 0x0800;
    }

    vaddr += (addr & 0x001F);
    vaddr += (addr & 0x0780) >> 1;

    return vaddr;
  }

  int32 wram_topleft;
  int32 wram_top;
  int32 wram_left;

  void determine_vram_bounds() {
    wram_topleft = int32(bus::read_u16(0x7E0084) >> 1);
    wram_top     = int32(wram_topleft >> 6);
    wram_left    = int32(wram_topleft & 0x3f);
  }

  void write_tilemap(uint i, uint16 tile, bool include_vram) {
    // record state change:
    state[i] = int32(tile);

    // write to WRAM:
    bus::write_u16(0x7E2000 + (i << 1), tile);

    // write to VRAM:
    if (!include_vram) return;

    // make sure tilemap offset is within VRAM screen range:
    auto top  = int32(i >> 6);
    auto left = int32(i & 0x3f);
    if (top  < wram_top - 2) return;
    if (top  > wram_top + 0xE+2) return;
    if (left < wram_left - 2) return;
    if (left > wram_left + 0x10+2) return;

    // convert tilemap address to VRAM address:
    uint16 vaddr = ow_tilemap_to_vram_address(i << 1);

    // look up tile in tile gfx:
    uint16 a = tile << 3;
    array<uint16> t(4);
    t[0] = bus::read_u16(0x0F8000 + a);
    t[1] = bus::read_u16(0x0F8002 + a);
    t[2] = bus::read_u16(0x0F8004 + a);
    t[3] = bus::read_u16(0x0F8006 + a);

    // update 16x16 tilemap in VRAM:
    ppu::vram.write_block(vaddr, 0, 2, t);
    ppu::vram.write_block(vaddr + 0x0020, 2, 2, t);
  }

  void apply(TilemapRun @run, bool include_vram) {
    // apply the run to the tilemap, overwriting any existing values:
    uint32 addr = run.offs;
    uint32 stride = run.vertical ? 0x40 : 1;

    if (run.same) {
      // use same tile value for entire run:
      for (uint n = 0; n < run.count; n++, addr += stride) {
        int32 tile = run.tile;
        if (state[addr] != tile) {
          serialized = false;
        }
        write_tilemap(addr, tile, include_vram);
      }
    } else {
      // use individual tile values at each step:
      for (uint n = 0; n < run.count; n++, addr += stride) {
        int32 tile = run.tiles[n];
        if (state[addr] != tile) {
          serialized = false;
        }
        write_tilemap(addr, tile, include_vram);
      }
    }
  }

  array<TilemapRun> runs;

  void serialize(array<uint8> @r) {
    if (!serialized) {
      // reset runs:
      runs.reserve(20);
      runs.resize(0);

      // copy the state to a tmp array so we can mutate it:
      array<int32> tmp = state;

      // $20 x $20 or $40 x $40
      uint width = size;
      uint height = size;
      uint stride = 0x40;

      //if ((rate_limit & 0x7f) == 0) {
      //  message("tilemap:");
      //  for (uint y = 0; y < height; y++) {
      //    string str = "";
      //    auto row = (y * stride);
      //    for (uint x = 0; x < width; x++) {
      //      // start a run at first tile that's not -1:
      //      auto tile = tmp[row + x];
      //      if (tile == -1) {
      //        str = str+"    ,";
      //      } else {
      //        str = str+fmtHex(tile,4)+",";
      //      }
      //      if (tile == -1) continue;
      //    }
      //    message(str);
      //  }
      //}

      for (uint y = 0; y < height; y++) {
        auto row = (y * stride);
        for (uint x = 0; x < width; x++) {
          // start a run at first tile that's not -1:
          auto tile = tmp[row + x];
          if (tile == -1) continue;

          // measure horizontal span:
          uint hcount = 1;
          bool hsame = true;
          for (uint n = x+1; n < width; n++) {
            auto i = row + n;
            if (tmp[i] == -1) break;
            if (tmp[i] != tile) hsame = false;
            hcount++;
          }

          // measure vertical span:
          uint vcount = 1;
          bool vsame = true;
          for (uint n = y+1; n < height; n++) {
            auto i = (n * stride) + x;
            if (tmp[i] == -1) break;
            if (tmp[i] != tile) vsame = false;
            vcount++;
          }

          // create the run:
          TilemapRun run;
          run.offs = row + x;
          if (vcount > hcount) {
            // vertical run:
            run.vertical = true;
            run.count = vcount;
            run.same = vsame;
            if (run.same) {
              run.tile = tile;
            } else {
              run.tiles.reserve(vcount);
            }

            // add each tile to the run:
            for (uint n = y; n < y + vcount; n++) {
              auto i = (n * stride) + x;
              if (!run.same) {
                run.tiles.insertLast(tmp[i]);
              }

              // mark as processed:
              tmp[i] = -1;
            }
          } else {
            // horizontal run:
            run.vertical = false;
            run.count = hcount;
            run.same = hsame;
            if (run.same) {
              run.tile = tile;
            } else {
              run.tiles.reserve(hcount);
            }

            // add each tile to the run:
            for (uint n = x; n < x + hcount; n++) {
              auto i = row + n;
              if (!run.same) {
                run.tiles.insertLast(tmp[i]);
              }

              // mark as processed:
              tmp[i] = -1;
            }
          }

          runs.insertLast(run);
        }
      }

      serialized = true;
    }

    // serialize runs to message:
    r.write_u8(runs.length());
    for (uint i = 0; i < runs.length(); i++) {
      auto @run = runs[i];
      //if ((rate_limit & 0x7f) == 0) {
      //  message( (run.vertical ? "vert" : "horz") + " " + (run.same ? "same" : "diff") + " offs="+fmtHex(run.offs,4)+" count="+fmtInt(run.count)+" tiles="+fmtHex(run.tile,4));
      //}
      run.serialize(r);
    }

    //rate_limit++;
  }
}

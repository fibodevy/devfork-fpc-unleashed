{
    This file is part of the Free Pascal run time library.
    Copyright (c) 1999-2000 by the Free Pascal development team

    Heap manager interface section

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}

{ Memorymanager }
type
  TFPCHeapStatus = record
    MaxHeapSize,
    MaxHeapUsed,
    CurrHeapSize,
    CurrHeapUsed,
    CurrHeapFree  : ptruint;
  end;
  THeapStatus = record
    TotalAddrSpace: Cardinal;
    TotalUncommitted: Cardinal;
    TotalCommitted: Cardinal;
    TotalAllocated: Cardinal;
    TotalFree: Cardinal;
    FreeSmall: Cardinal;
    FreeBig: Cardinal;
    Unused: Cardinal;
    Overhead: Cardinal;
    HeapErrorCode: Cardinal;
  end;

  PMemoryManager = ^TMemoryManager;
  TMemoryManager = record
    NeedLock            : boolean;   // Obsolete
    Getmem              : Function(Size:ptruint):Pointer;
    Freemem             : Function(p:pointer):ptruint;
    FreememSize         : Function(p:pointer;Size:ptruint):ptruint;
    AllocMem            : Function(Size:ptruint):Pointer;
    ReAllocMem          : Function(var p:pointer;Size:ptruint):Pointer;
    MemSize             : function(p:pointer):ptruint;
    InitThread          : procedure;
    DoneThread          : procedure;
    RelocateHeap        : procedure;
    GetHeapStatus       : function :THeapStatus;
    GetFPCHeapStatus    : function :TFPCHeapStatus;
  end;

procedure GetMemoryManager(var MemMgr: TMemoryManager);
procedure SetMemoryManager(const MemMgr: TMemoryManager);
function  IsMemoryManagerSet: Boolean;

{ Variables }
const
{$ifdef LEGACYHEAP}
  { if more than MaxKeptOSChunks are free, the heap manager will release chunks back to the OS }
  MaxKeptOSChunks: DWord = 4;
  growheapsizesmall : ptruint=32*1024; { fixed-size small blocks will grow with 32k }
  growheapsize1 : ptruint=256*1024;  { < 256k will grow with 256k }
{$endif LEGACYHEAP}
  growheapsize2 : ptruint=1024*1024; { > 256k will grow with 1m }
var
  ReturnNilIfGrowHeapFails : boolean;

{$ifndef FPC_NO_DEFAULT_HEAP}
{ Default MemoryManager functions }
Function  SysGetmem(Size:ptruint):Pointer;
Function  SysFreemem(p:pointer):ptruint;
Function  SysFreememSize(p:pointer;Size:ptruint):ptruint;
Function  SysMemSize(p:pointer):ptruint;
Function  SysAllocMem(size:ptruint):Pointer;
function  SysTryResizeMem(var p:pointer;size:ptruint):boolean;
Function  SysReAllocMem(var p:pointer;size:ptruint):Pointer;
function  SysGetHeapStatus:THeapStatus;
function  SysGetFPCHeapStatus:TFPCHeapStatus;
{$endif FPC_NO_DEFAULT_HEAP}

{$ifdef FPC_HAS_FEATURE_HEAP}
{ Tp7 functions }
Procedure Getmem(Out p:pointer;Size:ptruint);
Procedure Getmemory(Out p:pointer;Size:ptruint);
Procedure Freemem(p:pointer;Size:ptruint);
Procedure Freememory(p:pointer;Size:ptruint);

{ FPC additions }
Function  MemSize(p:pointer):ptruint;

{ Delphi functions }
function GetMem(size:ptruint):pointer; inline;
function GetMemory(size:ptruint):pointer; cdecl;
function Freemem(p:pointer):ptruint; inline;
function Freememory(p:pointer):ptruint; cdecl;
function AllocMem(Size:ptruint):pointer;
function ReAllocMem(var p:pointer;Size:ptruint):pointer; inline;
function ReAllocMemory(p:pointer;Size:ptruint):pointer; cdecl;
function GetHeapStatus:THeapStatus;
function GetFPCHeapStatus:TFPCHeapStatus;
{$endif FPC_HAS_FEATURE_HEAP}


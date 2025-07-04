{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Generates VMT for classes/objects and interface wrappers

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 ****************************************************************************
}
unit ncgvmt;

{$i fpcdefs.inc}

interface

    uses
      aasmdata,aasmbase,aasmcnst,
      symbase,symconst,symtype,symdef;

    type
      pprocdeftree = ^tprocdeftree;
      tprocdeftree = record
         data : tprocdef;
         nl   : tasmlabel;
         l,r  : pprocdeftree;
      end;

      TVMTWriter=class
      protected
        _Class : tobjectdef;
        { message tables }
        root : pprocdeftree;
        { implemented interface vtables }
        fintfvtablelabels: array of TAsmLabel;

        procedure disposeprocdeftree(p : pprocdeftree);
        procedure insertmsgint(p:TObject;arg:pointer);
        procedure insertmsgstr(p:TObject;arg:pointer);
        procedure insertint(p : pprocdeftree;var at : pprocdeftree;var count:longint);
        procedure insertstr(p : pprocdeftree;var at : pprocdeftree;var count:longint);
        function RedirectToEmpty(procdef: tprocdef): boolean;
        procedure writenames(tcb: ttai_typedconstbuilder; p: pprocdeftree);
        procedure writeintentry(tcb: ttai_typedconstbuilder; p: pprocdeftree; entrydef: tdef);
        procedure writestrentry(tcb: ttai_typedconstbuilder; p: pprocdeftree; entrydef: tdef);
{$ifdef WITHDMT}
        { dmt }
        procedure insertdmtentry(p:TObject;arg:pointer);
        procedure writedmtindexentry(p : pprocdeftree);
        procedure writedmtaddressentry(p : pprocdeftree);
{$endif}
        { published methods }
        procedure do_count_published_methods(p:TObject;arg:pointer);
        procedure do_gen_published_methods(p:TObject;arg:pointer);
        { virtual methods }
        procedure writevirtualmethods(tcb: ttai_typedconstbuilder);
        { interface tables }
        procedure intf_create_vtbl(tcb: ttai_typedconstbuilder; AImplIntf: TImplementedInterface; intfindex: longint);
        procedure intf_gen_intf_ref(tcb: ttai_typedconstbuilder; AImplIntf: TImplementedInterface; intfindex: longint; interfaceentrydef, interfaceentrytypedef: tdef);
        procedure intf_write_table(tcb: ttai_typedconstbuilder; out lab: TAsmLabel; out intftabledef: trecorddef);
        { generates the message tables for a class }
        procedure genstrmsgtab(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out msgstrtabledef: trecorddef);
        procedure genintmsgtab(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out msginttabledef: trecorddef);
        procedure genpublishedmethodstable(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out pubmethodsdef: trecorddef);
        procedure generate_field_table(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out fieldtabledef: trecorddef);
        procedure generate_abstract_stub(list:TAsmList;pd:tprocdef); virtual;
{$ifdef WITHDMT}
        { generates a DMT for _class }
        function  gendmt : tasmlabel;
{$endif WITHDMT}
      public
        constructor create(c:tobjectdef); virtual;
        { write the VMT to al_globals }
        procedure writevmt;
        procedure writeinterfaceids(list: TAsmList);
        { should the VMT writer be used at all (e.g., not for the JVM target) }
        class function use_vmt_writer: boolean; virtual;
      end;
      TVMTWriterClass = class of TVMTWriter;

    { generate VMTs }
    procedure write_vmts(st:tsymtable;is_global:boolean);

  var
    CVMTWriter: TVMTWriterClass = TVMTWriter;

implementation

    uses
      cutils,cclasses,
      fpchash,
      globtype,globals,verbose,constexp,
      systems,fmodule,
      symsym,symtable,symcreat,
{$ifdef cpuhighleveltarget}
      pparautl,
{$endif cpuhighleveltarget}
      aasmtai,
      wpobase,
      cgbase,parabase,paramgr,
      hlcgobj,hlcgcpu,dbgbase,
      ncgrtti;


{*****************************************************************************
                                TVMTWriter
*****************************************************************************}

    constructor TVMTWriter.create(c:tobjectdef);
      begin
        inherited Create;
        _Class:=c;
      end;


{**************************************
           Message Tables
**************************************}

    procedure TVMTWriter.disposeprocdeftree(p : pprocdeftree);
      begin
         if assigned(p^.l) then
           disposeprocdeftree(p^.l);
         if assigned(p^.r) then
           disposeprocdeftree(p^.r);
         dispose(p);
      end;


    procedure TVMTWriter.insertint(p : pprocdeftree;var at : pprocdeftree;var count:longint);
      begin
         if at=nil then
           begin
              at:=p;
              inc(count);
           end
         else
           begin
              if p^.data.messageinf.i<at^.data.messageinf.i then
                insertint(p,at^.l,count)
              else if p^.data.messageinf.i>at^.data.messageinf.i then
                insertint(p,at^.r,count)
              else
                Message1(parser_e_duplicate_message_label,tostr(p^.data.messageinf.i));
           end;
      end;


    procedure TVMTWriter.insertstr(p : pprocdeftree;var at : pprocdeftree;var count:longint);
      var
         i : integer;
      begin
         if at=nil then
           begin
              at:=p;
              inc(count);
           end
         else
           begin
              i:=CompareStr(p^.data.messageinf.str^,at^.data.messageinf.str^);
              if i<0 then
                insertstr(p,at^.l,count)
              else if i>0 then
                insertstr(p,at^.r,count)
              else
                Message1(parser_e_duplicate_message_label,p^.data.messageinf.str^);
           end;
      end;


    procedure TVMTWriter.insertmsgint(p:TObject;arg:pointer);
      var
        i  : longint;
        pd : Tprocdef;
        pt : pprocdeftree;
      begin
        if tsym(p).typ<>procsym then
          exit;
        for i:=0 to Tprocsym(p).ProcdefList.Count-1 do
          begin
            pd:=tprocdef(Tprocsym(p).ProcdefList[i]);
            if po_msgint in pd.procoptions then
              begin
                new(pt);
                pt^.data:=pd;
                pt^.l:=nil;
                pt^.r:=nil;
                insertint(pt,root,plongint(arg)^);
              end;
          end;
      end;


    procedure TVMTWriter.insertmsgstr(p:TObject;arg:pointer);
      var
        i  : longint;
        pd : Tprocdef;
        pt : pprocdeftree;
      begin
        if tsym(p).typ<>procsym then
          exit;
        for i:=0 to Tprocsym(p).ProcdefList.Count-1 do
          begin
            pd:=tprocdef(Tprocsym(p).ProcdefList[i]);
            if po_msgstr in pd.procoptions then
              begin
                new(pt);
                pt^.data:=pd;
                pt^.l:=nil;
                pt^.r:=nil;
                insertstr(pt,root,plongint(arg)^);
              end;
          end;
      end;


    procedure TVMTWriter.writenames(tcb: ttai_typedconstbuilder; p: pprocdeftree);
      var
        datatcb : ttai_typedconstbuilder;
        len : byte;
      begin
         if assigned(p^.l) then
           writenames(tcb,p^.l);
         tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,p^.nl);
         len:=length(p^.data.messageinf.str^);
         datatcb.maybe_begin_aggregate(carraydef.getreusable(cansichartype,len+1));
         datatcb.emit_tai(Tai_string.Create_Data(@p^.data.messageinf.str^[0],len+1,false),carraydef.getreusable(cansichartype,len+1));
         datatcb.maybe_end_aggregate(carraydef.getreusable(cansichartype,len+1));
         tcb.finish_internal_data_builder(datatcb,p^.nl,carraydef.getreusable(cansichartype,len+1),sizeof(pint));
         if assigned(p^.r) then
           writenames(tcb,p^.r);
      end;

    procedure TVMTWriter.writestrentry(tcb: ttai_typedconstbuilder; p: pprocdeftree; entrydef: tdef);
      begin
         if assigned(p^.l) then
           writestrentry(tcb,p^.l,entrydef);

         { write name label }
         tcb.maybe_begin_aggregate(entrydef);
         tcb.emit_tai(Tai_const.Create_sym(p^.nl),cpointerdef.getreusable(carraydef.getreusable(cansichartype,length(p^.data.messageinf.str^)+1)));
         tcb.queue_init(voidcodepointertype);
         tcb.queue_emit_proc(p^.data);
         tcb.maybe_end_aggregate(entrydef);

         if assigned(p^.r) then
           writestrentry(tcb,p^.r,entrydef);
     end;


    procedure TVMTWriter.genstrmsgtab(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out msgstrtabledef: trecorddef);
      var
         count : longint;
         datatcb: ttai_typedconstbuilder;
         msgstrentry: tdef;
         msgarraydef: tarraydef;
      begin
         root:=nil;
         count:=0;
         { insert all message handlers into a tree, sorted by name }
         _class.symtable.SymList.ForEachCall(@insertmsgstr,@count);

         { write all names }
         if assigned(root) then
           writenames(tcb,root);

         { now start writing the message string table }
         tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,lab);
         {
           TStringMessageTable = record
              count : longint;
              msgstrtable : array[0..0] of tmsgstrtable;
           end;

           Instead of 0 as the upper bound, use the actual upper bound
         }
         msgstrentry:=search_system_type('TMSGSTRTABLE').typedef;
         get_tabledef(itp_vmt_tstringmesssagetable,s32inttype,msgstrentry,count,0,msgstrtabledef,msgarraydef);
         { outer record (TStringMessageTable) }
         datatcb.maybe_begin_aggregate(msgstrtabledef);
         datatcb.emit_tai(Tai_const.Create_32bit(count),s32inttype);
         if assigned(root) then
           begin
              { array of TMsgStrTable }
              datatcb.maybe_begin_aggregate(msgarraydef);
              writestrentry(datatcb,root,msgstrentry);
              datatcb.maybe_end_aggregate(msgarraydef);
              disposeprocdeftree(root);
           end;
         datatcb.maybe_end_aggregate(msgstrtabledef);
         tcb.finish_internal_data_builder(datatcb,lab,msgstrtabledef,sizeof(pint));
      end;


    procedure TVMTWriter.writeintentry(tcb: ttai_typedconstbuilder; p: pprocdeftree; entrydef: tdef);
      begin
         if assigned(p^.l) then
           writeintentry(tcb,p^.l,entrydef);

         tcb.maybe_begin_aggregate(entrydef);
         { write integer dispatch number }
         tcb.emit_tai(Tai_const.Create_32bit(p^.data.messageinf.i),u32inttype);
         tcb.queue_init(voidcodepointertype);
         tcb.queue_emit_proc(p^.data);
         tcb.maybe_end_aggregate(entrydef);

         if assigned(p^.r) then
           writeintentry(tcb,p^.r,entrydef);
      end;


    procedure TVMTWriter.genintmsgtab(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out msginttabledef: trecorddef);
      var
         count : longint;
         datatcb: ttai_typedconstbuilder;
         msgintdef: trecorddef;
         msgintarrdef: tarraydef;
      begin
         root:=nil;
         count:=0;
         { insert all message handlers into a tree, sorted by name }
         _class.symtable.SymList.ForEachCall(@insertmsgint,@count);

         { now start writing of the message string table }

         { from objpas.inc:
             TMsgIntTable = record
                index : dword;
                method : codepointer;
             end;
         }
         msginttabledef:=get_recorddef(itp_vmt_intern_msgint_table,[u32inttype,voidcodepointertype],0);
         { from objpas.inc:
             TMsgInt = record
                count : longint;
                msgs : array[0..0] of TMsgIntTable;
             end;
         }
         tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,lab);
         get_tabledef(itp_vmt_msgint_table_entries,s32inttype,msginttabledef,count,0,msgintdef,msgintarrdef);
         datatcb.maybe_begin_aggregate(msgintdef);
         datatcb.emit_tai(Tai_const.Create_32bit(count),s32inttype);
         if assigned(root) then
           begin
              datatcb.maybe_begin_aggregate(msgintarrdef);
              writeintentry(datatcb,root,msginttabledef);
              datatcb.maybe_end_aggregate(msgintarrdef);
              disposeprocdeftree(root);
           end;
         datatcb.maybe_end_aggregate(msgintdef);
         tcb.finish_internal_data_builder(datatcb,lab,msgintdef,sizeof(pint));
      end;

{$ifdef WITHDMT}

{**************************************
              DMT
**************************************}

    procedure TVMTWriter.insertdmtentry(p:TObject;arg:pointer);

      var
         hp : tprocdef;
         pt : pprocdeftree;

      begin
         if tsym(p).typ=procsym then
           begin
              hp:=tprocsym(p).definition;
              while assigned(hp) do
                begin
                   if (po_msgint in hp.procoptions) then
                     begin
                        new(pt);
                        pt^.p:=hp;
                        pt^.l:=nil;
                        pt^.r:=nil;
                        insertint(pt,root);
                     end;
                   hp:=hp.nextoverloaded;
                end;
           end;
      end;

    procedure TVMTWriter.writedmtindexentry(p : pprocdeftree);

      begin
         if assigned(p^.l) then
           writedmtindexentry(p^.l);
         al_globals.concat(Tai_const.Create_32bit(p^.data.messageinf.i));
         if assigned(p^.r) then
           writedmtindexentry(p^.r);
      end;

    procedure TVMTWriter.writedmtaddressentry(p : pprocdeftree);

      begin
         if assigned(p^.l) then
           writedmtaddressentry(p^.l);
         al_globals.concat(Tai_const_symbol.Createname(p^.data.mangledname,0));
         if assigned(p^.r) then
           writedmtaddressentry(p^.r);
      end;

    function TVMTWriter.gendmt : tasmlabel;

      var
         r : tasmlabel;

      begin
         root:=nil;
         count:=0;
         gendmt:=nil;
         { insert all message handlers into a tree, sorted by number }
         _class.symtable.SymList.ForEachCall(insertdmtentry);

         if count>0 then
           begin
              current_asmdata.getglobaldatalabel(r);
              gendmt:=r;
              al_globals.concat(cai_align.create(sizeof(pint)));
              al_globals.concat(Tai_label.Create(r));
              { entries for caching }
              al_globals.concat(Tai_const.Create_ptr(0));
              al_globals.concat(Tai_const.Create_ptr(0));

              al_globals.concat(Tai_const.Create_32bit(count));
              if assigned(root) then
                begin
                   writedmtindexentry(root);
                   writedmtaddressentry(root);
                   disposeprocdeftree(root);
                end;
           end;
      end;

{$endif WITHDMT}

{**************************************
        Published Methods
**************************************}

    procedure TVMTWriter.do_count_published_methods(p:TObject;arg:pointer);
      var
        i  : longint;
        pd : tprocdef;
      begin
        if (tsym(p).typ<>procsym) then
          exit;
        for i:=0 to Tprocsym(p).ProcdefList.Count-1 do
          begin
            pd:=tprocdef(Tprocsym(p).ProcdefList[i]);
            if (pd.procsym=tsym(p)) and
               (pd.visibility=vis_published) then
              inc(plongint(arg)^);
          end;
      end;


    type
      tvmtasmoutput = record
        pubmethodstcb: ttai_typedconstbuilder;
        methodnamerec: trecorddef;
      end;
      pvmtasmoutput = ^tvmtasmoutput;

    procedure TVMTWriter.do_gen_published_methods(p:TObject;arg:pointer);
      var
        i  : longint;
        l  : tasmlabel;
        pd : tprocdef;
        lists: pvmtasmoutput absolute arg;
        datatcb  : ttai_typedconstbuilder;
        namedef : tdef;
      begin
        if (tsym(p).typ<>procsym) then
          exit;
        for i:=0 to Tprocsym(p).ProcdefList.Count-1 do
          begin
            pd:=tprocdef(Tprocsym(p).ProcdefList[i]);
            if (pd.procsym=tsym(p)) and
               (pd.visibility=vis_published) then
              begin
                { l: name_of_method }
                lists^.pubmethodstcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,l);
                namedef:=datatcb.emit_shortstring_const(tsym(p).realname);
                lists^.pubmethodstcb.finish_internal_data_builder(datatcb,l,namedef,sizeof(pint));
                { the tmethodnamerec }
                lists^.pubmethodstcb.maybe_begin_aggregate(lists^.methodnamerec);
                { convert the pointer to the name into a generic pshortstring,
                  so all entries can share the same recorddef }
                lists^.pubmethodstcb.queue_init(charpointertype);
                lists^.pubmethodstcb.queue_emit_asmsym(l,namedef);
                if po_abstractmethod in pd.procoptions then
                  lists^.pubmethodstcb.emit_tai(Tai_const.Create_nil_codeptr,voidcodepointertype)
                else
                  begin
                    { convert the procdef in a generic voidcodepointer, same
                      reason as above }
                    lists^.pubmethodstcb.queue_init(voidcodepointertype);
                    lists^.pubmethodstcb.queue_emit_proc(pd);
                  end;
                lists^.pubmethodstcb.maybe_end_aggregate(lists^.methodnamerec);
              end;
           end;
      end;


    procedure TVMTWriter.genpublishedmethodstable(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out pubmethodsdef: trecorddef);
      var
         count : longint;
         lists : tvmtasmoutput;
         pubmethodsarraydef: tarraydef;
         methodstabledef: trecorddef;
         datatcb: ttai_typedconstbuilder;
         packrecords: longint;
      begin
        // TODO(ryan): is extended method table packed?
        if (tf_requires_proper_alignment in target_info.flags) then
          packrecords:=0
        else
          packrecords:=1;

         count:=0;
         _class.symtable.SymList.ForEachCall(@do_count_published_methods,@count);
         if (count>0) or (_class.rtti.options[ro_methods]<>[]) then
           begin
              { in the list of the published methods (from objpas.inc):
                  tmethodnamerec = packed record
                     name : pshortstring;
                     addr : codepointer;
                  end;
              }
              lists.methodnamerec:=get_recorddef(itp_vmt_intern_tmethodnamerec,[cpointerdef.getreusable(cshortstringtype),voidcodepointertype],1);
              { from objpas.inc:
                  tmethodnametable = packed record
                    count : dword;
                    entries : packed array[0..0] of tmethodnamerec;
                  end;
               }
              tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,lists.pubmethodstcb,lab);
              get_tabledef(itp_vmt_intern_tmethodnametable,u32inttype,lists.methodnamerec,count,packrecords,pubmethodsdef,pubmethodsarraydef);
              { begin record ecompassing the tmethodnametable and the extended method table }
              lists.pubmethodstcb.begin_anonymous_record('',packrecords,
                  pubmethodsdef.alignment, targetinfos[target_info.system]^.alignment.recordalignmin);
              { begin tmethodnametable }
              lists.pubmethodstcb.maybe_begin_aggregate(pubmethodsdef);
              { emit count field }
              lists.pubmethodstcb.emit_tai(Tai_const.Create_32bit(count),u32inttype);
              if count>0 then
                begin
                  { begin entries field (array) }
                  lists.pubmethodstcb.maybe_begin_aggregate(pubmethodsarraydef);
                  { add all entries elements }
                  _class.symtable.SymList.ForEachCall(@do_gen_published_methods,@lists);
                  { end entries field (array) }
                  lists.pubmethodstcb.maybe_end_aggregate(pubmethodsarraydef);
                end;
              { end methodnametable }
              lists.pubmethodstcb.maybe_end_aggregate(pubmethodsdef);
              { write extended method rtti }
              RTTIWriter.write_extended_method_table(lists.pubmethodstcb,_class);
              { end the encompassing record }
              methodstabledef:=lists.pubmethodstcb.end_anonymous_record;
              tcb.finish_internal_data_builder(lists.pubmethodstcb,lab,methodstabledef,sizeof(pint));
           end
         else
           begin
             lab:=nil;
             pubmethodsdef:=nil;
           end;
      end;


    procedure TVMTWriter.generate_field_table(tcb: ttai_typedconstbuilder; out lab: tasmlabel; out fieldtabledef: trecorddef);
      var
        i   : longint;
        sym : tsym;
        classtable : tasmlabel;
        classindex,
        fieldcount : longint;
        classtablelist : TFPList;
        datatcb: ttai_typedconstbuilder;
        packrecords: longint;
        classdef: tobjectdef;
        classtabledef: trecorddef;
      begin
        classtable:=nil;
        classtablelist:=TFPList.Create;
        classtabledef:=nil;
        { retrieve field info fields }
        fieldcount:=0;
        for i:=0 to _class.symtable.SymList.Count-1 do
          begin
            sym:=tsym(_class.symtable.SymList[i]);
            if (sym.typ=fieldvarsym) and
               not(sp_static in sym.symoptions) and
               (sym.visibility=vis_published) then
             begin
                if tfieldvarsym(sym).vardef.typ<>objectdef then
                  internalerror(200611032);
                classindex:=classtablelist.IndexOf(tfieldvarsym(sym).vardef);
                if classindex=-1 then
                  classtablelist.Add(tfieldvarsym(sym).vardef);
                inc(fieldcount);
             end;
          end;

        if (fieldcount>0) or (_class.rtti.options[ro_fields]<>[]) then
          begin
            if (tf_requires_proper_alignment in target_info.flags) then
              packrecords:=0
            else
              packrecords:=1;

            { generate the class table }
            if classtablelist.count>0 then
              begin
                tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,classtable);
                datatcb.begin_anonymous_record('$fpc_intern_classtable_'+tostr(classtablelist.Count-1),
                  packrecords,1,
                  targetinfos[target_info.system]^.alignment.recordalignmin);
                datatcb.emit_tai(Tai_const.Create_16bit(classtablelist.count),u16inttype);
                for i:=0 to classtablelist.Count-1 do
                  begin
                    classdef:=tobjectdef(classtablelist[i]);
                    { type of the field }
                    datatcb.queue_init(voidpointertype);
                    { reference to the vmt }
                    datatcb.queue_emit_asmsym(
                      current_asmdata.RefAsmSymbol(classdef.vmt_mangledname,AT_DATA,true),
                      tfieldvarsym(classdef.vmt_field).vardef);
                  end;
                classtabledef:=datatcb.end_anonymous_record;
                tcb.finish_internal_data_builder(datatcb,classtable,classtabledef,sizeof(pint));
              end;

            { write fields }
            {
              TFieldTable =
             $ifndef FPC_REQUIRES_PROPER_ALIGNMENT
              packed
             $endif FPC_REQUIRES_PROPER_ALIGNMENT
              record
                FieldCount: Word;
                ClassTable: Pointer;
                Fields: array[0..0] of TFieldInfo
              end;
            }
            tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,lab);
            { can't easily specify a name here for reuse of the constructed def,
              since it's full of variable length shortstrings (-> all of those
              lengths and their order would have to incorporated in the name,
              plus there would be very little chance that it could actually be
              reused }
            datatcb.begin_anonymous_record('',packrecords,1,
              targetinfos[target_info.system]^.alignment.recordalignmin);
            datatcb.emit_tai(Tai_const.Create_16bit(fieldcount),u16inttype);
            if classtable<>nil then
              datatcb.emit_tai(Tai_const.Create_sym(classtable),cpointerdef.getreusable(classtabledef))
            else
              datatcb.emit_tai(tai_const.Create_nil_codeptr,voidpointertype);
            if fieldcount>0 then
              begin
                for i:=0 to _class.symtable.SymList.Count-1 do
                  begin
                    sym:=tsym(_class.symtable.SymList[i]);
                    if (sym.typ=fieldvarsym) and
                       not(sp_static in sym.symoptions) and
                      (sym.visibility=vis_published) then
                      begin
                        { skip non-object defs for legacy rtti }
                        if tfieldvarsym(sym).vardef.typ<>objectdef then
                          continue;
                        {
                          TFieldInfo =
                         $ifndef FPC_REQUIRES_PROPER_ALIGNMENT
                          packed
                         $endif FPC_REQUIRES_PROPER_ALIGNMENT
                          record
                            FieldOffset: SizeUInt;
                            ClassTypeIndex: Word;
                            Name: ShortString;
                          end;
                        }
                        datatcb.begin_anonymous_record('$fpc_intern_fieldinfo_'+tostr(length(tfieldvarsym(sym).realname)),packrecords,1,
                          targetinfos[target_info.system]^.alignment.recordalignmin);
                        datatcb.emit_tai(Tai_const.Create_sizeint(tfieldvarsym(sym).fieldoffset),sizeuinttype);
                        classindex:=classtablelist.IndexOf(tfieldvarsym(sym).vardef);
                        if classindex=-1 then
                          internalerror(200611033);
                        datatcb.emit_tai(Tai_const.Create_16bit(classindex+1),u16inttype);
                        datatcb.emit_shortstring_const(tfieldvarsym(sym).realname);
                        datatcb.end_anonymous_record;
                      end;
                  end;
              end;
            { append the extended rtti table }
            RTTIWriter.write_extended_field_table(datatcb,_class);
            fieldtabledef:=datatcb.end_anonymous_record;
            tcb.finish_internal_data_builder(datatcb,lab,fieldtabledef,sizeof(pint));
          end
        else
          begin
            fieldtabledef:=nil;
            lab:=nil;
          end;

        classtablelist.free;
      end;


{**************************************
           Interface tables
**************************************}

    function CreateWrapperName(_class : tobjectdef;AImplIntf : TImplementedInterface;i : longint;pd : tprocdef) : TSymStr;
      var
        realintfdef: tobjectdef;
        tmpstr : AnsiString;
        hs : TSymStr;
        hash : QWord;
      begin
        realintfdef:=AImplIntf.IntfDef;
        while realintfdef.is_unique_objpasdef do
          realintfdef:=realintfdef.childof;

        tmpstr:=_class.objname^+'_$_'+make_mangledname('',realintfdef.owner,'')+'_$$_'+realintfdef.objname^+'_$_'+tostr(i)+'_$_'+pd.mangledname;
        if length(tmpstr)>50 then
          begin
            hash:=InitFnv64;
            hash:=UpdateFnv64(hash,tmpstr[51],length(tmpstr)-50);
            hs:=copy(tmpstr,1,50)+'$H'+Base64Mangle(hash);
          end
        else
          hs:=tmpstr;
        result:=make_mangledname('WRPR',_class.owner,hs);
      end;


    procedure TVMTWriter.intf_create_vtbl(tcb: ttai_typedconstbuilder; AImplIntf: TImplementedInterface; intfindex: longint);
      var
        datatcb : ttai_typedconstbuilder;
        pd : tprocdef;
        hs : TSymStr;
        i  : longint;
      begin
        tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,'',datatcb,fintfvtablelabels[intfindex]);
        datatcb.begin_anonymous_record('',0,1,
          targetinfos[target_info.system]^.alignment.recordalignmin);
        if assigned(AImplIntf.procdefs) then
          begin
            for i:=0 to AImplIntf.procdefs.count-1 do
              begin
                pd:=tprocdef(AImplIntf.procdefs[i]);
                hs:=CreateWrapperName(_Class,AImplIntf,i,pd);
                { create reference }
                datatcb.emit_tai(Tai_const.Createname(hs,AT_FUNCTION,0),cprocvardef.getreusableprocaddr(pd,pc_address_only));
              end;
           end
        else
          { can't have an empty symbol on LLVM }
          datatcb.emit_tai(tai_const.Create_nil_codeptr,voidpointertype);
        tcb.finish_internal_data_builder(datatcb,fintfvtablelabels[intfindex],
          datatcb.end_anonymous_record,sizeof(pint));
      end;


    procedure TVMTWriter.intf_gen_intf_ref(tcb: ttai_typedconstbuilder; AImplIntf: TImplementedInterface; intfindex: longint; interfaceentrydef, interfaceentrytypedef: tdef);
      var
        pd: tprocdef;
        siid,
        siidstr: tsymstr;
        nonuniqueintf: tobjectdef;
      begin
        nonuniqueintf:=AImplIntf.IntfDef;
        while nonuniqueintf.is_unique_objpasdef do
          nonuniqueintf:=nonuniqueintf.childof;
        tcb.maybe_begin_aggregate(interfaceentrydef);
        { GUID (or nil for Corba interfaces) }
        tcb.next_field:=tabstractrecorddef(interfaceentrydef).symtable.Find('IIDREF') as tfieldvarsym;
        siid:='';
        if nonuniqueintf.objecttype in [odt_interfacecom] then
          begin
            siid:=make_mangledname('IID',nonuniqueintf.owner,nonuniqueintf.objname^);
            tcb.emit_tai(Tai_const.Create_sym_offset(
              current_asmdata.RefAsmSymbol(siid,AT_DATA,true),0),cpointerdef.getreusable(rec_tguid));
          end
        else
          tcb.emit_tai(Tai_const.Create_nil_dataptr,cpointerdef.getreusable(rec_tguid));

        { VTable }
        tcb.next_field:=tabstractrecorddef(interfaceentrydef).symtable.Find('VTABLE') as tfieldvarsym;
        tcb.queue_init(voidpointertype);
        tcb.queue_emit_asmsym(fintfvtablelabels[intfindex],nonuniqueintf);
        { IOffset field }
        case AImplIntf.VtblImplIntf.IType of
          etFieldValue, etFieldValueClass,
          etStandard:
            begin
              tcb.next_field:=tabstractrecorddef(interfaceentrydef).symtable.Find('IOFFSET') as tfieldvarsym;
              tcb.emit_tai(Tai_const.Create_sizeint(AImplIntf.VtblImplIntf.IOffset),sizeuinttype);
            end;
          etStaticMethodResult, etStaticMethodClass:
            begin
              tcb.next_field:=tabstractrecorddef(interfaceentrydef).symtable.Find('IOFFSETASCODEPTR') as tfieldvarsym;
              pd:=tprocdef(tpropertysym(AImplIntf.ImplementsGetter).propaccesslist[palt_read].procdef);
              tcb.queue_init(codeptruinttype);
              tcb.queue_emit_proc(pd);
            end;
          etVirtualMethodResult, etVirtualMethodClass:
            begin
              tcb.next_field:=tabstractrecorddef(interfaceentrydef).symtable.Find('IOFFSET') as tfieldvarsym;
              pd:=tprocdef(tpropertysym(AImplIntf.ImplementsGetter).propaccesslist[palt_read].procdef);
              tcb.emit_tai(Tai_const.Create_sizeint(tobjectdef(pd.struct).vmtmethodoffset(pd.extnumber)),sizeuinttype);
            end;
        end;

        { IIDStr }
        tcb.next_field:=tabstractrecorddef(interfaceentrydef).symtable.Find('IIDSTRREF') as tfieldvarsym;
        siidstr:=make_mangledname('IIDSTR',nonuniqueintf.owner,nonuniqueintf.objname^);
        tcb.queue_init(cpointerdef.getreusable(cshortstringtype));
        tcb.queue_emit_asmsym(
          current_asmdata.RefAsmSymbol(
            siidstr,
            AT_DATA,
            true),
          cpointerdef.getreusable(carraydef.getreusable(cansichartype,length(nonuniqueintf.iidstr^)+1)));
        { IType }
        tcb.next_field:=tabstractrecorddef(interfaceentrydef).symtable.Find('ITYPE') as tfieldvarsym;
        tcb.emit_ord_const(aint(AImplIntf.VtblImplIntf.IType),interfaceentrytypedef);
        tcb.maybe_end_aggregate(interfaceentrydef);

        if findunitsymtable(nonuniqueintf.owner).moduleid<>findunitsymtable(_Class.owner).moduleid then
          begin
            if siid<>'' then
              current_module.add_extern_asmsym(siid,AB_EXTERNAL,AT_DATA);
            current_module.add_extern_asmsym(siidstr,AB_EXTERNAL,AT_DATA);
          end;
      end;


    procedure TVMTWriter.intf_write_table(tcb: ttai_typedconstbuilder; out lab: TAsmLabel; out intftabledef: trecorddef);
      var
        i        : longint;
        ImplIntf : TImplementedInterface;
        datatcb      : ttai_typedconstbuilder;
        interfaceentrydef : tdef;
        interfaceentrytypedef: tdef;
        interfacearray: tdef;
      begin
        setlength(fintfvtablelabels,_class.ImplementedInterfaces.count);

        { Write unique vtbls }
        for i:=0 to _class.ImplementedInterfaces.count-1 do
          begin
            ImplIntf:=TImplementedInterface(_class.ImplementedInterfaces[i]);
            if ImplIntf.VtblImplIntf=ImplIntf then
              intf_create_vtbl(tcb,ImplIntf,i)
          end;
        { Set labels for aliased vtbls (after all unique vtbls have been
          written, so all labels have been defined already) }
        for i:=0 to _class.ImplementedInterfaces.count-1 do
          begin
            ImplIntf:=TImplementedInterface(_class.ImplementedInterfaces[i]);
            if ImplIntf.VtblImplIntf<>ImplIntf then
              fintfvtablelabels[i]:=fintfvtablelabels[_class.ImplementedInterfaces.IndexOf(ImplIntf.VtblImplIntf)];
          end;

        tcb.start_internal_data_builder(current_asmdata.AsmLists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,lab);
        datatcb.begin_anonymous_record('',default_settings.packrecords,1,
          targetinfos[target_info.system]^.alignment.recordalignmin);
        datatcb.emit_tai(Tai_const.Create_sizeint(_class.ImplementedInterfaces.count),sizeuinttype);
        interfaceentrydef:=search_system_type('TINTERFACEENTRY').typedef;
        interfaceentrytypedef:=search_system_type('TINTERFACEENTRYTYPE').typedef;
        if _class.ImplementedInterfaces.count>0 then
          begin
            interfacearray:=carraydef.getreusable(interfaceentrydef,_class.ImplementedInterfaces.count);
            datatcb.maybe_begin_aggregate(interfacearray);
            { Write vtbl references }
            for i:=0 to _class.ImplementedInterfaces.count-1 do
              begin
                ImplIntf:=TImplementedInterface(_class.ImplementedInterfaces[i]);
                intf_gen_intf_ref(datatcb,ImplIntf,i,interfaceentrydef,interfaceentrytypedef);
              end;
            datatcb.maybe_end_aggregate(interfacearray);
          end;
        intftabledef:=datatcb.end_anonymous_record;
        tcb.finish_internal_data_builder(datatcb,lab,intftabledef,intftabledef.alignment);

      end;


  { Write interface identifiers to the data section }
  procedure TVMTWriter.writeinterfaceids(list: TAsmList);
    var
      s : string;
      tcb : ttai_typedconstbuilder;
      def : tdef;
      sym : tasmsymbol;
    begin
      if assigned(_class.iidguid) then
        begin
          s:=make_mangledname('IID',_class.owner,_class.objname^);
          tcb:=ctai_typedconstbuilder.create([tcalo_make_dead_strippable,tcalo_data_force_indirect]);
          tcb.emit_guid_const(_class.iidguid^);
          sym:=current_asmdata.DefineAsmSymbol(s,AB_GLOBAL,AT_DATA_NOINDIRECT,rec_tguid);
          list.concatlist(tcb.get_final_asmlist(
            sym,
            rec_tguid,
            sec_rodata,
            s,
            sizeof(pint)));
          tcb.free;
          current_module.add_public_asmsym(sym);
        end;
      s:=make_mangledname('IIDSTR',_class.owner,_class.objname^);
      tcb:=ctai_typedconstbuilder.create([tcalo_make_dead_strippable,tcalo_data_force_indirect]);
      def:=tcb.emit_shortstring_const(_class.iidstr^);
      sym:=current_asmdata.DefineAsmSymbol(s,AB_GLOBAL,AT_DATA_NOINDIRECT,def);
      list.concatlist(tcb.get_final_asmlist(
        sym,
        def,
        sec_rodata,
        s,
        sizeof(pint)));
      tcb.free;
      current_module.add_public_asmsym(sym);
    end;


  class function TVMTWriter.use_vmt_writer: boolean;
    begin
      result:=true;
    end;


    function TVMTWriter.RedirectToEmpty(procdef : tprocdef) : boolean;
      var
        i : longint;
        hp : PCGParaLocation;
      begin
        result:=false;
        if procdef.isempty then
          begin
{$ifdef x86}
            paramanager.create_funcretloc_info(procdef,calleeside);
            if (procdef.funcretloc[calleeside].Location^.loc=LOC_FPUREGISTER) then
              exit;
{$endif x86}
            procdef.init_paraloc_info(callerside);
            { we can redirect the call if no memory parameter is passed }
            for i:=0 to procdef.paras.count-1 do
              begin
                hp:=tparavarsym(procdef.paras[i]).paraloc[callerside].Location;
                while assigned(hp) do
                  begin
                    if not(hp^.Loc in [LOC_REGISTER,LOC_MMREGISTER,LOC_FPUREGISTER]) then
                      exit;
                    hp:=hp^.Next;
                  end;
              end;
            result:=true;
          end;
      end;


    procedure TVMTWriter.generate_abstract_stub(list:TAsmList;pd:tprocdef);
      begin
        { Generate stubs for abstract methods, so their symbols are present and
          can be used e.g. to take address (see issue #24536). }
        if (po_global in pd.procoptions) and
           (pd.owner.defowner<>self._class) then
          exit;
        pd.synthetickind:=tsk_call_no_parameters;
        pd.skpara:=search_system_proc('ABSTRACTERROR');
        { abstract methods are not marked as forwarddef, because otherwise
          the compiler would accept implementations for them (and complain if
          they were missing); we are now after parsing the user code, so we can
          mark them again as forwarddef to indicate they need to be parsed }
        pd.forwarddef:=true;
      end;


    procedure TVMTWriter.writevirtualmethods(tcb: ttai_typedconstbuilder);
      var
         vmtpd : tprocdef;
         vmtentry : pvmtentry;
         i  : longint;
         procname : TSymStr;
{$ifdef vtentry}
         hs : string;
{$endif vtentry}
      begin
        for i:=0 to _class.VMTEntries.Count-1 do
         begin
           vmtentry:=pvmtentry(_class.vmtentries[i]);
           vmtpd:=vmtentry^.procdef;
           { safety checks }
           if not(po_virtualmethod in vmtpd.procoptions) then
             internalerror(200611082);
           if vmtpd.extnumber<>i then
             internalerror(200611083);
           if (po_abstractmethod in vmtpd.procoptions) then
             begin
               procname:='FPC_ABSTRACTERROR';
               generate_abstract_stub(current_asmdata.AsmLists[al_procedures],vmtpd);
             end
           else if (cs_opt_remove_empty_proc in current_settings.optimizerswitches) and RedirectToEmpty(vmtpd) then
             begin
               procname:='FPC_EMPTYMETHOD';
               if current_module.globalsymtable<>systemunit then
                 current_module.add_extern_asmsym(procname,AB_EXTERNAL,AT_FUNCTION);
             end
           else if not wpoinfomanager.optimized_name_for_vmt(_class,vmtpd,procname) then
             begin
               procname:=vmtpd.mangledname;
               if current_module.moduleid<>vmtpd.owner.moduleid then
                 current_module.addimportedsym(vmtpd.procsym);
             end;
           tcb.emit_tai(Tai_const.Createname(procname,AT_FUNCTION,0),cprocvardef.getreusableprocaddr(vmtpd,pc_address_only));
{$ifdef vtentry}
           hs:='VTENTRY'+'_'+_class.vmt_mangledname+'$$'+tostr(_class.vmtmethodoffset(i) div sizeof(pint));
           current_asmdata.asmlists[al_globals].concat(tai_symbol.CreateName(hs,AT_DATA,0,voidpointerdef));
{$endif vtentry}
         end;
      end;


    procedure TVMTWriter.writevmt;
      var
         methodnametable,intmessagetable,
         strmessagetable,classnamelabel,
         fieldtablelabel : tasmlabel;
{$ifdef vtentry}
         hs: string;
{$endif vtentry}
{$ifdef WITHDMT}
         dmtlabel : tasmlabel;
{$endif WITHDMT}
         interfacetable : tasmlabel;
         tcb, datatcb: ttai_typedconstbuilder;
         classnamedef: tdef;
         methodnametabledef,
         fieldtabledef,
         interfacetabledef,
         strmessagetabledef,
         intmessagetabledef: trecorddef;
         parentvmtdef: tdef;
         pinterfacetabledef,
         pstringmessagetabledef: tdef;
         vmttypesym: ttypesym;
         vmtdef: tdef;
         sym : TAsmSymbol;
      begin
{$ifdef WITHDMT}
         dmtlabel:=gendmt;
{$endif WITHDMT}
         { this code gets executed after the current module's symtable has
           already been removed from the symtablestack -> add it again, so that
           newly created defs here end up in the right unit }
         symtablestack.push(current_module.localsymtable);
         strmessagetable:=nil;
         interfacetable:=nil;
         fieldtablelabel:=nil;
         methodnametable:=nil;
         intmessagetable:=nil;
         classnamelabel:=nil;

         classnamedef:=nil;
         methodnametabledef:=nil;
         fieldtabledef:=nil;
         interfacetabledef:=nil;
         strmessagetabledef:=nil;
         intmessagetabledef:=nil;

         { generate VMT }
         tcb:=ctai_typedconstbuilder.create([tcalo_make_dead_strippable,tcalo_data_force_indirect]);

         { write tables for classes, this must be done before the actual
           class is written, because we need the labels defined }
         if is_class(_class) then
          begin
            { write class name }
            tcb.start_internal_data_builder(current_asmdata.asmlists[al_const],sec_rodata,_class.vmt_mangledname,datatcb,classnamelabel);
            classnamedef:=datatcb.emit_shortstring_const(_class.RttiName, m_no_rtti in current_settings.modeswitches);
            tcb.finish_internal_data_builder(datatcb,classnamelabel,classnamedef,sizeof(pint));

            { interface table }
            if _class.implements_any_interfaces then
              intf_write_table(tcb,interfacetable,interfacetabledef);

            genpublishedmethodstable(tcb,methodnametable,methodnametabledef);
            generate_field_table(tcb,fieldtablelabel,fieldtabledef);

            { generate message and dynamic tables }
            if (oo_has_msgstr in _class.objectoptions) then
              genstrmsgtab(tcb,strmessagetable,strmessagetabledef);
            if (oo_has_msgint in _class.objectoptions) then
              genintmsgtab(tcb,intmessagetable,intmessagetabledef);
          end;

         { reuse the type created in nobj, so we get internal consistency
           checking for free }
         vmttypesym:=ttypesym(_class.symtable.find('vmtdef'));
         if not assigned(vmttypesym) or
            (vmttypesym.typ<>typesym) or
            (vmttypesym.typedef.typ<>recorddef) then
           internalerror(2015071403);
         vmtdef:=trecorddef(vmttypesym.typedef);

         tcb.maybe_begin_aggregate(vmtdef);

         { determine the size with symtable.datasize, because }
         { size gives back 4 for classes                    }
         tcb.emit_ord_const(tObjectSymtable(_class.symtable).datasize,sizesinttype);
         tcb.emit_ord_const(-int64(tObjectSymtable(_class.symtable).datasize),sizesinttype);
{$ifdef WITHDMT}
         if _class.classtype=ct_object then
           begin
              if assigned(dmtlabel) then
                tcb.emit_tai(dmtlabel,voidpointertype)
              else
                tcb.emit_tai(Tai_const.Create_nil_dataptr,voidpointertype);
           end;
{$endif WITHDMT}
         { write pointer to parent VMT, this isn't implemented in TP }
         { but this is not used in FPC ? (PM) }
         { it's not used yet, but the delphi-operators as and is need it (FK) }
         { it is not written for parents that don't have any vmt !! }
         if is_class(_class) then
           parentvmtdef:=cpointerdef.getreusable(search_system_type('TVMT').typedef)
         else
           parentvmtdef:=voidpointertype;
         if assigned(_class.childof) and
            (oo_has_vmt in _class.childof.objectoptions) then
           begin
             tcb.queue_init(parentvmtdef);
             sym:=current_asmdata.RefAsmSymbol(_class.childof.vmt_mangledname,AT_DATA,true);
             tcb.queue_emit_asmsym(
               sym,
               tfieldvarsym(_class.childof.vmt_field).vardef);
             if _class.childof.owner.moduleid<>current_module.moduleid then
               current_module.add_extern_asmsym(sym);
           end
         else
           tcb.emit_tai(Tai_const.Create_nil_dataptr,parentvmtdef);

         { write extended info for classes, for the order see rtl/inc/objpash.inc }
         if is_class(_class) then
          begin
            { pointer to class name string }
            tcb.queue_init(cpointerdef.getreusable(cshortstringtype));
            tcb.queue_emit_asmsym(classnamelabel,classnamedef);
            { pointer to dynamic table or nil }
            if (oo_has_msgint in _class.objectoptions) then
              begin
                tcb.queue_init(voidpointertype);
                tcb.queue_emit_asmsym(intmessagetable,cpointerdef.getreusable(intmessagetabledef));
              end
            else
              tcb.emit_tai(Tai_const.Create_nil_dataptr,voidpointertype);
            { pointer to method table or nil }
            if assigned(methodnametable) then
              begin
                tcb.queue_init(voidpointertype);
                tcb.queue_emit_asmsym(methodnametable,cpointerdef.getreusable(methodnametabledef))
              end
            else
              tcb.emit_tai(Tai_const.Create_nil_dataptr,voidpointertype);
            { pointer to field table }
            if assigned(fieldtablelabel) then
              begin
                tcb.queue_init(voidpointertype);
                tcb.queue_emit_asmsym(fieldtablelabel,fieldtabledef)
              end
            else
              tcb.emit_tai(Tai_const.Create_nil_dataptr,voidpointertype);
            { pointer to type info of published section }
            tcb.emit_tai(Tai_const.Create_sym(RTTIWriter.get_rtti_label(_class,fullrtti,false)),voidpointertype);
            { inittable for con-/destruction }
            if _class.members_need_inittable then
              tcb.emit_tai(Tai_const.Create_sym(RTTIWriter.get_rtti_label(_class,initrtti,false)),voidpointertype)
            else
              tcb.emit_tai(Tai_const.Create_nil_dataptr,voidpointertype);
            { auto table }
            tcb.emit_tai(Tai_const.Create_nil_dataptr,voidpointertype);
            { interface table }
            pinterfacetabledef:=search_system_type('PINTERFACETABLE').typedef;
            if _class.implements_any_interfaces then
              begin
                tcb.queue_init(pinterfacetabledef);
                tcb.queue_emit_asmsym(interfacetable,interfacetabledef)
              end
            else
              tcb.emit_tai(Tai_const.Create_nil_dataptr,pinterfacetabledef);
            { table for string messages }
            pstringmessagetabledef:=search_system_type('PSTRINGMESSAGETABLE').typedef;
            if (oo_has_msgstr in _class.objectoptions) then
              begin
                tcb.queue_init(voidpointertype);
                tcb.queue_emit_asmsym(strmessagetable,pstringmessagetabledef);
              end
            else
              tcb.emit_tai(Tai_const.Create_nil_dataptr,pstringmessagetabledef);
          end;
         { write virtual methods }
         writevirtualmethods(tcb);
         tcb.emit_tai(Tai_const.Create_nil_codeptr,voidcodepointertype);

         tcb.maybe_end_aggregate(vmtdef);

         sym:=current_asmdata.DefineAsmSymbol(_class.vmt_mangledname,AB_GLOBAL,AT_DATA_NOINDIRECT,vmtdef);
         current_module.add_public_asmsym(sym);

         { concatenate the VMT to the asmlist }
         current_asmdata.asmlists[al_globals].concatlist(
           tcb.get_final_asmlist(
             sym,
             vmtdef,sec_rodata,_class.vmt_mangledname,sizeof(pint)
           )
         );
         tcb.free;
{$ifdef vtentry}
         { write vtinherit symbol to notify the linker of the class inheritance tree }
         hs:='VTINHERIT'+'_'+_class.vmt_mangledname+'$$';
         if assigned(_class.childof) then
           hs:=hs+_class.childof.vmt_mangledname
         else
           hs:=hs+_class.vmt_mangledname;
         current_asmdata.asmlists[al_globals].concat(tai_symbol.CreateName(hs,AT_DATA,0,voidpointerdef));
{$endif vtentry}
        symtablestack.pop(current_module.localsymtable);
      end;


    procedure gen_intf_wrapper(list:TAsmList;_class:tobjectdef);
      var
        i,j  : longint;
        tmps : string;
        pd   : TProcdef;
        ImplIntf : TImplementedInterface;
        wrapperpd: tprocdef;
        wrapperinfo: pskpara_interface_wrapper;
        tmplist: tasmlist;
        oldfileposinfo: tfileposinfo;
        usehighlevelwrapper: Boolean;
      begin
{$if defined(cpuhighleveltarget)}
        usehighlevelwrapper:=true;
{$else defined(cpuhighleveltarget)}
        { on PPC systems that use a TOC the linker needs to be able to insert
          an instruction to restore the TOC register after every branch
          between code fragments that use a different TOC (which has to be
          executed when that "branch" returns). So we can't use tail call
          branches to routines potentially using a different TOC there }
        if target_info.abi in abis_ppc_toc then
          usehighlevelwrapper:=true
        else
          usehighlevelwrapper:=false;
{$endif defined(cpuhighleveltarget)}
        for i:=0 to _class.ImplementedInterfaces.count-1 do
          begin
            ImplIntf:=TImplementedInterface(_class.ImplementedInterfaces[i]);
            if (ImplIntf=ImplIntf.VtblImplIntf) and
               assigned(ImplIntf.ProcDefs) then
              begin
                for j:=0 to ImplIntf.ProcDefs.Count-1 do
                  begin
                    pd:=TProcdef(ImplIntf.ProcDefs[j]);
                    { we don't track method calls via interfaces yet ->
                      assume that every method called via an interface call
                      is reachable for now }
                    if (po_virtualmethod in pd.procoptions) and
                       not is_objectpascal_helper(tprocdef(pd).struct) then
                      tobjectdef(tprocdef(pd).struct).register_vmt_call(tprocdef(pd).extnumber);
                    tmps:=CreateWrapperName(_Class,ImplIntf,j,pd);

                  if usehighlevelwrapper then
                    begin
                      new(wrapperinfo);
                      wrapperinfo^.pd:=pd;
                      wrapperinfo^.offset:=ImplIntf.ioffset;
                      { insert the wrapper procdef in the current unit's local
                        symbol table, but set the owning "struct" to the current
                        class (so self will have the correct type) }
                      wrapperpd:=create_procdef_alias(pd,tmps,tmps,
                        current_module.localsymtable,_class,
                        tsk_interface_wrapper,wrapperinfo);
                      include(wrapperpd.implprocoptions,pio_thunk);
                    end
                  else
                    begin
                      oldfileposinfo:=current_filepos;
                      if pd.owner.iscurrentunit then
                        current_filepos:=pd.fileinfo
                      else
                        begin
                          current_filepos.moduleindex:=current_module.unit_index;
                          current_filepos.fileindex:=1;
                          current_filepos.line:=1;
                          current_filepos.column:=1;
                        end;
                      { create wrapper code }
                      tmplist:=tasmlist.create;
                      new_section(tmplist,sec_code,tmps,target_info.alignment.procalign);
                      tmplist.Concat(tai_function_name.create(tmps));
                      hlcg.init_register_allocators;
                      hlcg.g_intf_wrapper(tmplist,pd,tmps,ImplIntf.ioffset);
                      hlcg.done_register_allocators;
                      if ((cs_debuginfo in current_settings.moduleswitches) or
                         (cs_use_lineinfo in current_settings.globalswitches)) and
                         (target_dbg.id<>dbg_stabx) then
                           current_debuginfo.insertlineinfo(tmplist);
                      list.concatlist(tmplist);
                      tmplist.Free;
                      current_filepos:=oldfileposinfo;
                    end;
                  end;
              end;
          end;
      end;


    procedure do_write_vmts(st:tsymtable;is_global:boolean);
      var
        i : longint;
        def : tdef;
        vmtwriter  : TVMTWriter;
      begin
        if not CVMTWriter.use_vmt_writer then
          exit;
        for i:=0 to st.DefList.Count-1 do
          begin
            def:=tdef(st.DefList[i]);
            case def.typ of
              recorddef :
                do_write_vmts(trecorddef(def).symtable,is_global);
              objectdef :
                begin
                  { Skip generics and forward defs }
                  if ([df_generic,df_genconstraint]*def.defoptions<>[]) or
                     (oo_is_forward in tobjectdef(def).objectoptions) then
                    continue;
                  if tobjectdef(def).is_unique_objpasdef then
                    continue;
                  do_write_vmts(tobjectdef(def).symtable,is_global);
                  { Write also VMT if not done yet }
                  if not(ds_vmt_written in def.defstates) then
                    begin
                      vmtwriter:=CVMTWriter.create(tobjectdef(def));
                      if is_interface(tobjectdef(def)) then
                        vmtwriter.writeinterfaceids(current_asmdata.AsmLists[al_globals]);
                      if (oo_has_vmt in tobjectdef(def).objectoptions) then
                        vmtwriter.writevmt;
                      vmtwriter.free;
                      include(def.defstates,ds_vmt_written);
                    end;
                  if is_class(def) then
                    gen_intf_wrapper(current_asmdata.asmlists[al_procedures],tobjectdef(def));
                end;
              procdef :
                begin
                  if assigned(tprocdef(def).localst) and
                     (tprocdef(def).localst.symtabletype=localsymtable) then
                    do_write_vmts(tprocdef(def).localst,false);
                  if assigned(tprocdef(def).parast) then
                    do_write_vmts(tprocdef(def).parast,false);
                end;
              else
                ;
            end;
          end;
      end;

    procedure write_vmts(st:tsymtable;is_global:boolean);
      begin
{$ifndef cpuhighleveltarget}
        create_hlcodegen;
{$endif}
        do_write_vmts(st,is_global);
{$ifndef cpuhighleveltarget}
        destroy_hlcodegen;
{$endif}
      end;

end.

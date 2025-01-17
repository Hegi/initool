(* initool -- manipulate the contents of INI files from the command line
 * Copyright (c) 2015-2018, 2023 D. Bohdan
 * License: MIT
 *)

structure Id =
struct
  (* A section or key identifier. *)
  datatype id =
    StrId of string
  | Wildcard

  val empty = StrId ""

  type options = {ignoreCase: bool}

  fun normalize (opts: options) (StrId s) =
        if #ignoreCase opts then StrId (String.map Char.toLower s) else StrId s
    | normalize opts Wildcard = Wildcard

  fun same (opts: options) (a: id) (b: id) : bool =
    let in
      case (a, b) of
        (Wildcard, _) => true
      | (_, Wildcard) => true
      | _ => (normalize opts a) = (normalize opts b)
    end

  fun fromString s = StrId s

  fun fromStringWildcard "*" = Wildcard
    | fromStringWildcard s = StrId s

  fun toString id' =
    case id' of
      StrId s => s
    | Wildcard => "*"
end

structure Ini =
struct
  (* Model an INI file starting with key=value pairs. *)
  type property = {key: Id.id, value: string}
  datatype item = Property of property | Empty | Comment of string
  type section = {name: Id.id, contents: item list}
  type ini_data = section list

  datatype line_token =
    CommentLine of string
  | EmptyLine
  | PropertyLine of property
  | SectionLine of section
  datatype operation =
    Noop
  | SelectSection of Id.id
  | SelectProperty of {section: Id.id, key: Id.id}
  | RemoveSection of Id.id
  | RemoveProperty of {section: Id.id, key: Id.id}
  | UpdateProperty of {section: Id.id, key: Id.id, newValue: string}


  exception Tokenization of string

  (* A very rough tokenizer for INI lines. *)
  fun tokenizeLine (rawLine: string) : line_token =
    let
      fun split c s =
        let
          val fields = String.fields (fn ch => ch = c) s
        in
          case fields of
            [] => []
          | x :: [] => [x]
          | x :: xs => [x, String.concatWith (String.str c) xs]
        end
      val trimWhitespace = StringTrim.all [" ", "\t"]
      val line = trimWhitespace rawLine
      val isComment =
        (String.isPrefix ";" line) orelse (String.isPrefix "#" line)
      val isSection =
        (String.isPrefix "[" line) andalso (String.isSuffix "]" line)
      val keyAndValue = List.map trimWhitespace (split #"=" line)
    in
      case (line, isComment, isSection, keyAndValue) of
        ("[]", _, _, _) => raise Tokenization ("empty section name")
      | (_, true, _, _) => CommentLine (line)
      | (_, false, true, _) =>
          let
            val size = String.size line
            val sectionName = String.substring (line, 1, size - 2)
          in
            SectionLine {name = Id.fromString sectionName, contents = []}
          end
      | ("", false, false, _) => EmptyLine
      | (_, false, false, key :: value) =>
          (case value of
             [] => raise Tokenization ("invalid line: \"" ^ line ^ "\"")
           | _ =>
               PropertyLine
                 {key = Id.fromString key, value = String.concatWith "=" value})
      | (_, false, false, _) => raise Tokenization ("invalid line: " ^ line)
    end

  (* Transform a list of tokens into a simple AST for the INI file. *)
  fun makeSections (lines: line_token list) (acc: section list) : ini_data =
    let
      fun addItem (newItem: item) (sl: section list) =
        case sl of
          (y: section) :: ys =>
            {name = #name y, contents = newItem :: (#contents y)} :: ys
        | [] => [{name = Id.fromString "", contents = [newItem]}]
    in
      case lines of
        [] =>
          map (fn x => {name = #name x, contents = rev (#contents x)}) (rev acc)
      | SectionLine (sec) :: xs => makeSections xs (sec :: acc)
      | PropertyLine (prop) :: xs =>
          makeSections xs (addItem (Property prop) acc)
      | CommentLine (comment) :: xs =>
          makeSections xs (addItem (Comment comment) acc)
      | EmptyLine :: xs => makeSections xs (addItem Empty acc)
    end

  fun parse (lines: string list) : ini_data =
    let val tokenizedLines = map tokenizeLine lines
    in makeSections tokenizedLines []
    end

  fun stringifySection (sec: section) : string =
    let
      fun stringifyItem (i: item) =
        case i of
          Property prop => Id.toString (#key prop) ^ "=" ^ (#value prop)
        | Comment c => c
        | Empty => ""
      val header =
        case Id.toString (#name sec) of
          "" => ""
        | sectionName => "[" ^ sectionName ^ "]\n"
      val body = List.map stringifyItem (#contents sec)
    in
      header ^ (String.concatWith "\n" body)
    end

  fun stringify (ini: ini_data) : string =
    let val sections = map stringifySection ini
    val concat = String.concatWith "\n" sections
    in
      if concat = "" then "" else concat ^ "\n"
    end


  (* Say whether the item i in section sec should be returned under
   * the operation opr.
   *)
  fun matchOp (opts: Id.options) (opr: operation) (sec: section) (i: item) :
    bool =
    let
      val sectionName = #name sec
      val matches = Id.same opts
    in
      case (opr, i) of
        (Noop, _) => true
      | (SelectSection osn, _) => matches osn sectionName
      | (SelectProperty {section = osn, key = okey}, Property {key, value = _}) =>
          matches osn sectionName andalso matches okey key
      | (SelectProperty {section = osn, key = okey}, Comment c) => false
      | (SelectProperty {section = osn, key = okey}, Empty) => false
      | (RemoveSection osn, _) => not (matches osn sectionName)
      | (RemoveProperty {section = osn, key = okey}, Property {key, value = _}) =>
          not (matches osn sectionName andalso matches okey key)
      | (RemoveProperty {section = osn, key = okey}, Comment _) => true
      | (RemoveProperty {section = osn, key = okey}, Empty) => true
      | ( UpdateProperty {section = osn, key = okey, newValue = nv}
        , Property {key, value = _}
        ) => matches osn sectionName andalso matches okey key
      | (UpdateProperty {section = osn, key = okey, newValue = nv}, Comment _) =>
          false
      | (UpdateProperty {section = osn, key = okey, newValue = nv}, Empty) =>
          false
    end

  fun select (opts: Id.options) (opr: operation) (ini: ini_data) : ini_data =
    let
      fun selectItems (opr: operation) (sec: section) : section =
        { name = (#name sec)
        , contents = List.filter (matchOp opts opr sec) (#contents sec)

        }
      val sectionsFiltered =
        case opr of
          SelectSection osn =>
            List.filter (fn sec => Id.same opts osn (#name sec)) ini
        | SelectProperty {section = osn, key = _} =>
            List.filter (fn sec => Id.same opts osn (#name sec)) ini
        | RemoveSection osn =>
            List.filter (fn sec => not (Id.same opts osn (#name sec))) ini
        | _ => ini
    in
      List.map (selectItems opr) sectionsFiltered
    end

  (* Find replacement values in from for the existing properties in to.
   * This function makes n^2 comparisons and is hence slow.
   *)
  fun mergeSection (opts: Id.options) (from: section) (to: section) : section =
    let
      fun itemsEqual (i1: item) (i2: item) : bool =
        case (i1, i2) of
          (Property p1, Property p2) => Id.same opts (#key p2) (#key p1)
        | (_, _) => false
      fun findReplacements (replacementSource: item list) i1 =
        let
          val replacement: item option =
            List.find (itemsEqual i1) replacementSource
        in
          case (replacement, i1) of
            (SOME (Property new), Property orig) =>
              (* Preserve the original key, which may differ in case. *)
              Property {key = #key orig, value = #value new}

          | (SOME other, _) => other
          | (NONE, _) => i1
        end
      fun missingIn (items: item list) (i1: item) : bool =
        not (List.exists (itemsEqual i1) items)
      fun addBeforeEmpty (from: item list) (to: item list) : item list =
        let
          fun emptyCount l i =
            case l of
              Empty :: xs => emptyCount xs (i + 1)
            | _ => i
          val revTo = List.rev to
          val revToEmptyCount = emptyCount revTo 0
        in
          List.rev (List.drop (revTo, revToEmptyCount)) @ from
          @ List.take (revTo, revToEmptyCount)
        end
      val updatedItems =
        List.map (findReplacements (#contents from)) (#contents to)
      val newItems = List.filter (missingIn updatedItems) (#contents from)
      val mergedItems = addBeforeEmpty newItems updatedItems
    in
      {name = (#name to), contents = mergedItems}
    end

  (* This function makes n^2 comparisons and is hence slow. *)
  fun merge (opts: Id.options) (from: ini_data) (to: ini_data) : ini_data =
    let
      fun mergeOrKeep sec1 =
        let
          val secToMerge =
            List.find (fn sec2 => Id.same opts (#name sec2) (#name sec1)) from
        in
          case secToMerge of
            SOME (sec2) => mergeSection opts sec2 sec1
          | NONE => sec1
        end
      fun missingIn (ini: ini_data) (sec1: section) : bool =
        not
          (List.exists (fn sec2 => Id.same opts (#name sec2) (#name sec1)) ini)

      val updatedIni = List.map mergeOrKeep to
      val newSections = List.filter (missingIn updatedIni) from
      val prepend = List.find (fn sec => #name sec = Id.empty) newSections
      val append = List.filter (fn sec => #name sec <> Id.empty) newSections
      val prependPadded =
        case prepend of
          NONE => []
        | SOME (prependSec) =>
            (* Add an empty line after top-level properties if there are
            * sections following them. *)
            if updatedIni <> [] orelse append <> [] then
              [{ name = (#name prependSec)
               , contents = (#contents prependSec) @ [Empty]
               }]
            else
              [prependSec]
    in
      prependPadded @ updatedIni @ append
    end

  fun sectionExists (opts: Id.options) (section: Id.id) (ini: ini_data) =
    let val q = SelectSection section
    in select opts q ini <> []
    end

  fun propertyExists (opts: Id.options) (section: Id.id) (key: Id.id)
    (ini: ini_data) =
    let
      val q = SelectProperty {section = section, key = key}
      val sections = select opts q ini
    in
      List.exists
        (fn {contents = (Property _ :: _), name = _} => true | _ => false)
        sections
    end

  fun removeEmptySections (sections: ini_data) =
    List.filter (fn {contents = [], name = _} => false | _ => true) sections
end

{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Parse.Module
  ( fromByteString
  , Header(..)
  , Effects(..)
  , chompImports
  )
  where


import qualified Data.ByteString as BS
import qualified Data.Name as Name

import qualified AST.Source as Src
import qualified Elm.Compiler.Imports as Imports
import qualified Elm.Package as Pkg
import qualified Parse.Declaration as Decl
import qualified Parse.Keyword as Keyword
import qualified Parse.Space as Space
import qualified Parse.Symbol as Symbol
import qualified Parse.Variable as Var
import qualified Parse.Primitives as P
import Parse.Primitives hiding (State, fromByteString)
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Syntax as E



-- FROM BYTE STRING


fromByteString :: Pkg.Name -> BS.ByteString -> Either E.Error Src.Module
fromByteString pkg source =
  case P.fromByteString (chompModule pkg) source of
    P.Ok modul _ -> checkModule modul
    P.Err err    -> Left (E.ParseError err)



-- MODULE


data Module =
  Module
    { _header :: Maybe Header
    , _comment :: Maybe Src.Comment
    , _imports :: [Src.Import]
    , _infixes :: [A.Located Src.Infix]
    , _decls :: [Decl.Decl]
    }


chompModule :: Pkg.Name -> Parser E.Module Module
chompModule pkg =
  do  freshLine E.FreshLine
      header <- chompHeader
      comment <- chompModuleDocComment
      imports <- chompImports (if pkg == Pkg.core then [] else Imports.defaults)
      infixes <- if Pkg.isKernel pkg then chompInfixes [] else return []
      decls <- specialize E.Declarations $ chompDecls []
      endOfFile
      return (Module header comment imports infixes decls)



-- CHECK MODULE


checkModule :: Module -> Either E.Error Src.Module
checkModule (Module maybeHeader maybeComment imports infixes decls) =
  let
    (values, unions, aliases, ports) = categorizeDecls [] [] [] [] decls

    docs =
      case maybeComment of
        Just c  -> Just (Src.Docs c (getComments decls []))
        Nothing -> Nothing
  in
  case maybeHeader of
    Just (Header name effects exports) ->
      Src.Module (Just name) exports docs imports values unions aliases infixes
        <$> checkEffects ports effects

    Nothing ->
      Right $
        Src.Module Nothing (A.At A.one Src.Open) docs imports values unions aliases infixes $
          case ports of
            [] -> Src.NoEffects
            _:_ -> Src.Ports ports


checkEffects :: [Src.Port] -> Effects -> Either E.Error Src.Effects
checkEffects ports effects =
  case effects of
    NoEffects region ->
      case ports of
        []  -> Right Src.NoEffects
        _:_ -> Left (E.UnexpectedPort region)

    Ports region ->
      case ports of
        []  -> Left (E.NoPorts region)
        _:_ -> Right (Src.Ports ports)

    Manager region manager ->
      case ports of
        []  -> Right (Src.Manager region manager)
        _:_ -> Left (E.UnexpectedPort region)


categorizeDecls :: [A.Located Src.Value] -> [A.Located Src.Union] -> [A.Located Src.Alias] -> [Src.Port] -> [Decl.Decl] -> ( [A.Located Src.Value], [A.Located Src.Union], [A.Located Src.Alias], [Src.Port] )
categorizeDecls values unions aliases ports decls =
  case decls of
    [] ->
      (values, unions, aliases, ports)

    decl:otherDecls ->
      case decl of
        Decl.Value _ value -> categorizeDecls (value:values) unions aliases ports otherDecls
        Decl.Union _ union -> categorizeDecls values (union:unions) aliases ports otherDecls
        Decl.Alias _ alias -> categorizeDecls values unions (alias:aliases) ports otherDecls
        Decl.Port  _ port_ -> categorizeDecls values unions aliases (port_:ports) otherDecls


getComments :: [Decl.Decl] -> [(Name.Name,Src.Comment)] -> [(Name.Name,Src.Comment)]
getComments decls comments =
  case decls of
    [] ->
      comments

    decl:otherDecls ->
      case decl of
        Decl.Value c (A.At _ (Src.Value n _ _ _)) -> getComments otherDecls (addComment c n comments)
        Decl.Union c (A.At _ (Src.Union n _ _  )) -> getComments otherDecls (addComment c n comments)
        Decl.Alias c (A.At _ (Src.Alias n _ _  )) -> getComments otherDecls (addComment c n comments)
        Decl.Port  c         (Src.Port  n _    )  -> getComments otherDecls (addComment c n comments)


addComment :: Maybe Src.Comment -> A.Located Name.Name -> [(Name.Name,Src.Comment)] -> [(Name.Name,Src.Comment)]
addComment maybeComment (A.At _ name) comments =
  case maybeComment of
    Just comment -> (name, comment) : comments
    Nothing      -> comments



-- FRESH LINES


freshLine :: (Row -> Col -> E.Module) -> Parser E.Module ()
freshLine toFreshLineError =
  do  Space.chomp E.ModuleSpace
      Space.checkFreshLine toFreshLineError


endOfFile :: Parser E.Module ()
endOfFile =
  P.Parser $ \state@(P.State pos end _ row col) _ eok _ eerr ->
    if pos < end then
      eerr row col E.ModuleEndOfFile
    else
      eok () state



-- CHOMP DECLARATIONS


chompDecls :: [Decl.Decl] -> Parser E.Decl [Decl.Decl]
chompDecls decls =
  do  (decl, _) <- Decl.declaration
      oneOfWithFallback
        [ do  Space.checkFreshLine E.DeclFreshLineStart
              chompDecls (decl:decls)
        ]
        (reverse (decl:decls))


chompInfixes :: [A.Located Src.Infix] -> Parser E.Module [A.Located Src.Infix]
chompInfixes infixes =
  oneOfWithFallback
    [ do  binop <- Decl.infix_
          chompInfixes (binop:infixes)
    ]
    infixes



-- MODULE DOC COMMENT


chompModuleDocComment :: Parser E.Module (Maybe Src.Comment)
chompModuleDocComment =
  oneOfWithFallback
    [
      do  docComment <- Space.docComment E.ImportStart E.ModuleSpace
          Space.chomp E.ModuleSpace
          Space.checkFreshLine E.FreshLine
          return (Just docComment)
    ]
    Nothing



-- HEADER


data Header =
  Header (A.Located Name.Name) Effects (A.Located Src.Exposing)


data Effects
  = NoEffects A.Region
  | Ports A.Region
  | Manager A.Region Src.Manager


chompHeader :: Parser E.Module (Maybe Header)
chompHeader =
  do  start <- getPosition
      oneOfWithFallback
        [
          -- module MyThing exposing (..)
          do  Keyword.module_ E.ModuleProblem
              end <- getPosition
              Space.chompAndCheckIndent E.ModuleSpace E.ModuleProblem
              name <- addLocation (Var.moduleName E.ModuleName)
              Space.chompAndCheckIndent E.ModuleSpace E.ModuleProblem
              Keyword.exposing_ E.ModuleProblem
              Space.chompAndCheckIndent E.ModuleSpace E.ModuleProblem
              exports <- addLocation (specialize E.ModuleExposing exposing)
              freshLine E.FreshLine
              return (Just (Header name (NoEffects (A.Region start end)) exports))
        ,
          -- port module MyThing exposing (..)
          do  Keyword.port_ E.PortModuleProblem
              Space.chompAndCheckIndent E.ModuleSpace E.PortModuleProblem
              Keyword.module_ E.PortModuleProblem
              end <- getPosition
              Space.chompAndCheckIndent E.ModuleSpace E.PortModuleProblem
              name <- addLocation (Var.moduleName E.PortModuleName)
              Space.chompAndCheckIndent E.ModuleSpace E.PortModuleProblem
              Keyword.exposing_ E.PortModuleProblem
              Space.chompAndCheckIndent E.ModuleSpace E.PortModuleProblem
              exports <- addLocation (specialize E.PortModuleExposing exposing)
              freshLine E.FreshLine
              return (Just (Header name (Ports (A.Region start end)) exports))
        ,
          -- effect module MyThing where { command = MyCmd } exposing (..)
          do  Keyword.effect_ E.Effect
              Space.chompAndCheckIndent E.ModuleSpace E.Effect
              Keyword.module_ E.Effect
              end <- getPosition
              Space.chompAndCheckIndent E.ModuleSpace E.Effect
              name <- addLocation (Var.moduleName E.ModuleName)
              Space.chompAndCheckIndent E.ModuleSpace E.Effect
              Keyword.where_ E.Effect
              Space.chompAndCheckIndent E.ModuleSpace E.Effect
              manager <- chompManager
              Space.chompAndCheckIndent E.ModuleSpace E.Effect
              Keyword.exposing_ E.Effect
              Space.chompAndCheckIndent E.ModuleSpace E.Effect
              exports <- addLocation (specialize (const E.Effect) exposing)
              freshLine E.FreshLine
              return (Just (Header name (Manager (A.Region start end) manager) exports))
        ]
        -- default header
        Nothing


chompManager :: Parser E.Module Src.Manager
chompManager =
  do  word1 0x7B {- { -} E.Effect
      spaces_em
      oneOf E.Effect
        [ do  cmd <- chompCommand
              spaces_em
              oneOf E.Effect
                [ do  word1 0x7D {-}-} E.Effect
                      spaces_em
                      return (Src.Cmd cmd)
                , do  word1 0x2C {-,-} E.Effect
                      spaces_em
                      sub <- chompSubscription
                      spaces_em
                      word1 0x7D {-}-} E.Effect
                      spaces_em
                      return (Src.Fx cmd sub)
                ]
        , do  sub <- chompSubscription
              spaces_em
              oneOf E.Effect
                [ do  word1 0x7D {-}-} E.Effect
                      spaces_em
                      return (Src.Sub sub)
                , do  word1 0x2C {-,-} E.Effect
                      spaces_em
                      cmd <- chompCommand
                      spaces_em
                      word1 0x7D {-}-} E.Effect
                      spaces_em
                      return (Src.Fx cmd sub)
                ]
        ]


chompCommand :: Parser E.Module (A.Located Name.Name)
chompCommand =
  do  Keyword.command_ E.Effect
      spaces_em
      word1 0x3D {-=-} E.Effect
      spaces_em
      addLocation (Var.upper E.Effect)


chompSubscription :: Parser E.Module (A.Located Name.Name)
chompSubscription =
  do  Keyword.subscription_ E.Effect
      spaces_em
      word1 0x3D {-=-} E.Effect
      spaces_em
      addLocation (Var.upper E.Effect)


spaces_em :: Parser E.Module ()
spaces_em =
  Space.chompAndCheckIndent E.ModuleSpace E.Effect



-- IMPORTS


chompImports :: [Src.Import] -> Parser E.Module [Src.Import]
chompImports imports =
  oneOfWithFallback
    [ do  Keyword.import_ E.ImportStart
          Space.chompAndCheckIndent E.ModuleSpace E.ImportIndentName
          name@(A.At (A.Region _ end) _) <- addLocation (Var.moduleName E.ImportName)
          Space.chomp E.ModuleSpace
          oneOf E.ImportEnd
            [ do  Space.checkFreshLine E.ImportEnd
                  chompImports $
                    Src.Import name Nothing (Src.Explicit []) : imports
            , do  Space.checkIndent end E.ImportEnd
                  oneOf E.ImportAs
                    [ chompAs name imports
                    , chompExposing name Nothing imports
                    ]
            ]
    ]
    (reverse imports)


chompAs :: A.Located Name.Name -> [Src.Import] -> Parser E.Module [Src.Import]
chompAs name imports =
  do  Keyword.as_ E.ImportAs
      Space.chompAndCheckIndent E.ModuleSpace E.ImportIndentAlias
      alias <- Var.upper E.ImportAlias
      end <- getPosition
      Space.chomp E.ModuleSpace
      oneOf E.ImportEnd
        [ do  Space.checkFreshLine E.ImportEnd
              chompImports $
                Src.Import name (Just alias) (Src.Explicit []) : imports
        , do  Space.checkIndent end E.ImportEnd
              chompExposing name (Just alias) imports
        ]


chompExposing :: A.Located Name.Name -> Maybe Name.Name -> [Src.Import] -> Parser E.Module [Src.Import]
chompExposing name maybeAlias imports =
  do  Keyword.exposing_ E.ImportExposing
      Space.chompAndCheckIndent E.ModuleSpace E.ImportIndentExposingList
      exposed <- specialize E.ImportExposingList exposing
      freshLine E.ImportEnd
      chompImports $
        Src.Import name maybeAlias exposed : imports



-- LISTING


exposing :: Parser E.Exposing Src.Exposing
exposing =
  do  word1 0x28 {-(-} E.ExposingStart
      Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentValue
      oneOf E.ExposingIndentValue
        [ do  word2 0x2E 0x2E {-..-} E.ExposingIndentValue
              Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentEnd
              word1 0x29 {-)-} E.ExposingEnd
              return Src.Open
        , do  exposed <- addLocation chompExposed
              Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentEnd
              exposingHelp [exposed]
        ]


exposingHelp :: [A.Located Src.Exposed] -> Parser E.Exposing Src.Exposing
exposingHelp revExposed =
  oneOf E.ExposingEnd
    [ do  word1 0x2C {-,-} E.ExposingEnd
          Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentValue
          exposed <- addLocation chompExposed
          Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentValueEnd
          exposingHelp (exposed:revExposed)
    , do  word1 0x29 {-)-} E.ExposingEnd
          return (Src.Explicit (reverse revExposed))
    ]


chompExposed :: Parser E.Exposing Src.Exposed
chompExposed =
  oneOf E.ExposingValue
    [ Src.Lower <$> Var.lower E.ExposingValue
    , do  word1 0x28 {-(-} E.ExposingValue
          op <- Symbol.operator E.ExposingOperator E.ExposingOperatorReserved
          word1 0x29 {-)-} E.ExposingOperatorRightParen
          return (Src.Operator op)
    , do  name <- Var.upper E.ExposingValue
          Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentTypePrivacy
          Src.Upper name <$> privacy
    ]


privacy :: Parser E.Exposing Src.Privacy
privacy =
  oneOfWithFallback
    [ do  word1 0x28 {-(-} E.ExposingTypePrivacy
          Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentTypePrivacyDots
          word2 0x2E 0x2E {-..-} E.ExposingTypePrivacyDots
          Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentTypePrivacyEnd
          word1 0x29 {-)-} E.ExposingTypePrivacyEnd
          return Src.Public
    ]
    Src.Private

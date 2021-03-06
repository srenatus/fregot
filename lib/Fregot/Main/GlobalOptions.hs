{-# LANGUAGE TemplateHaskell #-}
module Fregot.Main.GlobalOptions
    ( Format (..)

    , GlobalOptions (..), verbosity, format
    , parseGlobalOptions

    , inputPath
    ) where

import           Control.Lens.TH              (makeLenses)
import qualified Options.Applicative.Extended as OA

data Format
    = Text
    | Json
    deriving (Bounded, Enum, Show)

data GlobalOptions = GlobalOptions
    { _verbosity :: ()  -- Placeholder
    , _format    :: Format
    } deriving (Show)

$(makeLenses ''GlobalOptions)

parseGlobalOptions :: OA.Parser GlobalOptions
parseGlobalOptions = GlobalOptions
    <$> pure ()
    <*> OA.plainEnumOption (
            OA.value Text <>
            OA.long "format" <>
            OA.metavar "FORMAT" <>
            OA.help "Format for error messages and diagnostics" <>
            OA.hidden)

inputPath :: OA.Parser (Maybe FilePath)
inputPath = OA.optional $ OA.strOption $
    OA.metavar "PATH" <>
    OA.long    "input" <>
    OA.short   'i' <>
    OA.help    "Input filepath"

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Fregot.Main.Bundle
    ( Options
    , parseOptions

    , main
    ) where

import           Control.Lens            ((^.))
import           Control.Lens.TH         (makeLenses)
import           Control.Monad.Extended  (forM_)
import qualified Control.Monad.Parachute as Parachute
import qualified Data.IORef              as IORef
import qualified Fregot.Error            as Error
import qualified Fregot.Find             as Find
import qualified Fregot.Interpreter      as Interpreter
import qualified Fregot.Sources          as Sources
import qualified Options.Applicative     as OA
import           System.Exit             (ExitCode (..))
import qualified System.IO               as IO

data Options = Options
    { _output :: !FilePath
    , _paths  :: [FilePath]
    } deriving (Show)

$(makeLenses ''Options)

parseOptions :: OA.Parser Options
parseOptions = Options
    <$> (OA.strOption $
            OA.short   'o' <>
            OA.long    "output" <>
            OA.metavar "BUNDLE" <>
            OA.help    "Path of output file")
    <*> (OA.some $ OA.strArgument $
            OA.metavar "PATHS" <>
            OA.help    "Rego files or directories to test")

main :: Options -> IO ExitCode
main opts = do
    sources <- Sources.newHandle
    interpreter <- Interpreter.newHandle sources
    regoPaths <- Find.findRegoFiles (opts ^. paths)
    (errors, _) <- Parachute.runParachuteT $ do
        forM_ regoPaths $ \path -> Interpreter.loadModule interpreter path
        Interpreter.saveBundle interpreter (opts ^. output)

    sources' <- IORef.readIORef sources
    Error.hPutErrors IO.stderr sources' Error.TextFmt errors

    return ExitSuccess
module Axel.Parse.Args where
import qualified Axel.Parse.AST as AST
import Data.Semigroup((<>))
import Options.Applicative(Parser,argument,command,info,metavar,progDesc,str,subparser)
data Command = Convert FilePath|File FilePath|Project |Version 
commandParser  = (subparser ((<>) projectCommand ((<>) fileCommand ((<>) convertCommand versionCommand)))) where {convertCommand  = (command "convert" (info ((<$>) Convert (argument str (metavar "FILE"))) (progDesc "(EXPERIMENTAL) Convert a Haskell file to Axel")));fileCommand  = (command "file" (info ((<$>) File (argument str (metavar "FILE"))) (progDesc "Build and run a single file")));projectCommand  = (command "project" (info (pure Project) (progDesc "Build and run the project")));versionCommand  = (command "version" (info (pure Version) (progDesc "Display the version of the Axel compiler")))}
commandParser :: (Parser Command)
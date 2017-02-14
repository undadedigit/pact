{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      :  Pact.Server.PactService
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Service to provide Pact interpreter and backend.
--

module Pact.Server.PactService
  (initPactService
  ) where

import Control.Concurrent
import Data.Default
import Data.Aeson as A


import Control.Monad.Reader
import Control.Exception.Safe
import Control.Applicative
import Control.Lens hiding ((.=))
import Data.Maybe
import qualified Text.Trifecta as TF
import qualified Data.Attoparsec.Text as AP
import Control.Monad.Except
import Prelude hiding (log,exp)
import qualified Data.HashMap.Strict as HM
import Text.PrettyPrint.ANSI.Leijen (renderCompact,displayS)
import System.Directory

import Pact.Types.Runtime hiding (PublicKey)
import Pact.Pure
import Pact.Eval
import Pact.Compile as Pact

import Pact.Types.Server
import Pact.Types.RPC
import Pact.Native (initEvalEnv)
import Pact.Types.Command
import Pact.Server.SQLite as PactSL


type PactMVars = (DBVar,MVar CommandState)

initPactService :: CommandConfig -> IO (CommandExecInterface PactRPC)
initPactService config@CommandConfig {..} = do
  let klog s = _ccDebugFn ("[PactService] " ++ s)
  mvars <- case _ccDbFile of
    Nothing -> do
      klog "Initializing pure pact"
      ee <- initEvalEnv def puredb
      rv <- newMVar (CommandState $ _eeRefStore ee)
      return (PureVar $ _eePactDbVar ee,rv)
    Just f -> do
      klog "Initializing pact SQLLite"
      dbExists <- doesFileExist f
      when dbExists $ klog "Deleting Existing Pact DB File" >> removeFile f
      p <- (\a -> a { _log = \m s -> _ccDebugFn $ "[Pact SQLite] " ++ m ++ ": " ++ show s }) <$> initPSL _ccPragmas _ccDebugFn f
      ee <- initEvalEnv p psl
      rv <- newMVar (CommandState $ _eeRefStore ee)
      let v = _eePactDbVar ee
      klog "Creating Pact Schema"
      createSchema v
      return (PSLVar v,rv)
  return CommandExecInterface
    { _ceiApplyCmd = \eMode cmd -> applyTransactionalPCmd config mvars eMode cmd (verifyCommand cmd)
    , _ceiApplyPPCmd = applyTransactionalPCmd config mvars }

applyTransactionalPCmd :: CommandConfig -> PactMVars -> ExecutionMode -> Command a -> ProcessedCommand PactRPC -> IO CommandResult
applyTransactionalPCmd _ _ ex cmd (ProcFail s) = return $ jsonResult ex (cmdToRequestKey cmd) s
applyTransactionalPCmd conf@CommandConfig {..} (dbv,cv) exMode _ (ProcSucc cmd) = do
  r <- tryAny $ runCommand (CommandEnv conf exMode dbv cv) $ runPayload cmd
  case r of
    Right cr -> do
      _ccDebugFn $ "[PactService]: tx success for requestKey: " ++ show (cmdToRequestKey cmd)
      return cr
    Left e -> do
      _ccDebugFn $ "[PactService]: tx failure for requestKey: " ++ show (cmdToRequestKey cmd) ++ ": " ++ show e
      return $ jsonResult exMode (cmdToRequestKey cmd) $
               CommandError "Transaction execution failed" (Just $ show e)

jsonResult :: ToJSON a => ExecutionMode -> RequestKey -> a -> CommandResult
jsonResult ex cmd a = CommandResult cmd (exToTx ex) (toJSON a)

exToTx :: ExecutionMode -> Maybe TxId
exToTx (Transactional t) = Just t
exToTx Local = Nothing

runPayload :: Command (Payload PactRPC) -> CommandM CommandResult
runPayload c@PublicCommand{..} =
  case _pPayload _cmdPayload of
    (Exec pm) -> applyExec (cmdToRequestKey c) pm _cmdSigs
    (Continuation ym) -> applyContinuation ym _cmdSigs

parse :: ExecutionMode -> Text -> CommandM [Exp]
parse (Transactional _) code =
    case AP.parseOnly Pact.exprs code of
      Right s -> return s
      Left e -> throwCmdEx $ "Pact parse failed: " ++ e
parse Local code =
    case TF.parseString Pact.exprs mempty (unpack code) of
      TF.Success s -> return s
      TF.Failure f -> throwCmdEx $ "Pact parse failed: " ++
                      displayS (renderCompact (TF._errDoc f)) ""

applyExec :: RequestKey -> ExecMsg -> [UserSig] -> CommandM CommandResult
applyExec rk (ExecMsg code edata) ks = do
  CommandEnv {..} <- ask
  exps <- parse _ceMode code
  when (null exps) $ throwCmdEx "No expressions found"
  terms <- forM exps $ \exp -> case compile (mkTextInfo code) exp of
            Right r -> return r
            Left err -> throwCmdEx $ show err
  (CommandState refStore) <- liftIO $ readMVar _ceState
  let tid = exToTx _ceMode
      evalEnv :: PactDb e -> MVar e -> EvalEnv e
      evalEnv pdb mv = EvalEnv {
                  _eeRefStore = refStore
                , _eeMsgSigs = userSigsToPactKeySet ks
                , _eeMsgBody = edata
                , _eeTxId = fromMaybe 0 tid
                , _eeEntity = _ccEntity _ceConfig
                , _eePactStep = Nothing
                , _eePactDb = pdb
                , _eePactDbVar = mv
                }
      runP (PureVar mv) = runEval def (evalEnv puredb mv) (execTerms _ceMode terms)
      runP (PSLVar mv) = runEval def (evalEnv psl mv) (execTerms _ceMode terms)
  (r,rEvalState') <- liftIO $ runP _ceDBVar
  case r of
    Right t -> do
           when (_ceMode /= Local) $ liftIO $ modifyMVar_ _ceState $ \rs ->
             return $ over (csRefStore.rsModules)
                      (HM.union (HM.fromList (_rsNew (_evalRefs rEvalState')))) rs
           return $ jsonResult _ceMode rk $ CommandSuccess t -- TODO Yield handling
    Left e -> throwCmdEx $ "Exec failed: " ++ show e

execTerms :: ExecutionMode -> [Term Name] -> Eval e (Term Name)
execTerms mode terms = do
  evalBeginTx def
  er <- catchError
        (last <$> mapM eval terms)
        (\e -> evalRollbackTx def >> throwError e)
  case mode of
    Transactional _ -> void $ evalCommitTx def
    Local -> evalRollbackTx def
  return er

applyContinuation :: ContMsg -> [UserSig] -> CommandM CommandResult
applyContinuation _ _ = throwCmdEx "Continuation not supported"

--mkRPC :: ToRPC a => a ->  CommandEntry
--mkRPC = CommandEntry . SZ.encode . PublicMessage . toStrict . A.encode . A.toJSON . toRPC
--
--mkSimplePact :: Text -> CommandEntry
--mkSimplePact = mkRPC . (`ExecMsg` A.Null)
--
--mkTestPact :: CommandEntry
--mkTestPact = mkSimplePact "(demo.transfer \"Acct1\" \"Acct2\" 1.0)"



--mkTestSigned :: IO ()
--mkTestSigned = do
--  (Right (msg :: PactRPC)) <- eitherDecode <$> BSL.readFile "tests/exec1.json"
--  let env@PactEnvelope {..} = PactEnvelope msg "a" "rid"
--  let (pm@PactMessage {..}) = mkPactMessage' _sk _pk  (BSL.toStrict $ A.encode env)
--      ce = CommandEntry $! SZ.encode $! PublicMessage $! _pmEnvelope
--      rpc = mkCmdRpc ce _peAlias "rid" (Digest _peAlias _pmSig _pmKey CMD $ hash $ SZ.encode $ CMDWire (ce,_peAlias,"rid"))
--      Right (c :: Command) = fromWire Nothing def rpc
--      cmdbrpc = mkCmdBatchRPC [rpc] (Digest _peAlias _pmSig _pmKey CMDB $ hash $ SZ.encode $ [rpc])
--      Right (cb :: CommandBatch) = fromWire Nothing def cmdbrpc
--  BSL.writeFile "tests/exec1-signed.json" $ encodePretty pm
--  (Just pm') <- A.decode <$> BSL.readFile "tests/exec1-signed.json"
--  print (pm == pm')
--  print c
--  print cb

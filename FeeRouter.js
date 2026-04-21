/** 

 * VerifyVault — Fee Router 

 * verifyvault.eth 

 * 

 * Calculates, injects, and routes all platform fees to the 

 * verified payout wallet on every trade execution. 

 * 

 * Payout wallet: bc1q59lrkvzn3ylspmy9fy58uc69xz0tj0j32v0na0 

 * 

 * Fee structure: 

 *   Platform fee : 1.5%  → payout wallet 

 *   Network fee  : 0.5%  → payout wallet 

 *   ───────────────────── 

 *   Total        : 2.0%  per trade 

 */ 

 

const FeeRouter = (() => { 

 

  // ─── CONFIG ──────────────────────────────────────────────────────────────── 

  const PAYOUT_WALLET  = 'bc1q59lrkvzn3ylspmy9fy58uc69xz0tj0j32v0na0'; 

  const PLATFORM_FEE   = 0.015;   // 1.5% 

  const NETWORK_FEE    = 0.005;   // 0.5% 

  const TOTAL_FEE_RATE = 0.020;   // 2.0% 

  const MIN_FEE_SATS   = 1000;    // floor: 1000 sats (~$0.70) min fee per trade 

  const DUST_THRESHOLD = 546;     // Bitcoin dust limit in sats 

 

  // ─── FEE CALCULATION ─────────────────────────────────────────────────────── 

  /** 

   * Calculate all fees for a trade. 

   * 

   * @param {number} tokenAmount    - number of tokens 

   * @param {number} priceInSats    - sats per token 

   * @param {number} btcUsdRate     - current BTC/USD price 

   * @param {string} action         - 'buy' | 'sell' 

   * 

   * @returns {object} Full fee breakdown 

   */ 

  function calculate(tokenAmount, priceInSats, btcUsdRate, action = 'buy') { 

    const totalSats      = tokenAmount * priceInSats; 

    const totalBTC       = totalSats / 1e8; 

    const subtotalUSD    = totalBTC * btcUsdRate; 

 

    const platformFeeSats = Math.max(Math.floor(totalSats * PLATFORM_FEE), MIN_FEE_SATS); 

    const networkFeeSats  = Math.floor(totalSats * NETWORK_FEE); 

    const totalFeesSats   = platformFeeSats + networkFeeSats; 

 

    const platformFeeUSD  = (platformFeeSats / 1e8) * btcUsdRate; 

    const networkFeeUSD   = (networkFeeSats  / 1e8) * btcUsdRate; 

    const totalFeesUSD    = platformFeeUSD + networkFeeUSD; 

 

    // Buyer pays fees on top; seller has fees deducted 

    const finalUSD = action === 'buy' 

      ? subtotalUSD + totalFeesUSD 

      : subtotalUSD - totalFeesUSD; 

 

    const finalSats = action === 'buy' 

      ? totalSats + totalFeesSats 

      : totalSats - totalFeesSats; 

 

    return { 

      tokenAmount, 

      priceInSats, 

      totalSats, 

      totalBTC, 

      subtotalUSD, 

      platformFeeSats, 

      networkFeeSats, 

      totalFeesSats, 

      platformFeeUSD, 

      networkFeeUSD, 

      totalFeesUSD, 

      finalUSD, 

      finalSats, 

      payoutWallet: PAYOUT_WALLET, 

      feeRate:      TOTAL_FEE_RATE, 

      action 

    }; 

  } 

 

  // ─── PSBT FEE INJECTION ──────────────────────────────────────────────────── 

  /** 

   * Inject the fee output into a PSBT before signing. 

   * 

   * In Bitcoin, we add an explicit output: 

   *   { address: PAYOUT_WALLET, value: totalFeesSats } 

   * 

   * This uses the bitcoin-psbt library (loaded from backend or CDN). 

   * In production, this call goes through the backend API to avoid 

   * exposing the PSBT manipulation to the client. 

   * 

   * @param {string} psbtBase64  - base64-encoded PSBT from UniSat market API 

   * @param {number} feeSats     - sats to route to payout wallet 

   * @returns {string}           - modified PSBT base64 with fee output added 

   */ 

  async function injectFeeOutput(psbtBase64, feeSats) { 

    if (feeSats < DUST_THRESHOLD) { 

      console.warn('Fee below dust threshold, skipping injection'); 

      return psbtBase64; 

    } 

 

    // In browser: delegate to backend /api/inject-fee which handles PSBT manipulation 

    // This keeps private key ops server-side 

    const res = await fetch('/api/inject-fee', { 

      method:  'POST', 

      headers: { 'Content-Type': 'application/json' }, 

      body: JSON.stringify({ 

        psbt:          psbtBase64, 

        feeSats:       feeSats, 

        payoutWallet:  PAYOUT_WALLET 

      }) 

    }); 

 

    if (!res.ok) throw new Error('Fee injection failed: ' + res.status); 

    const data = await res.json(); 

    return data.psbt; 

  } 

 

  // ─── SIGN + BROADCAST ────────────────────────────────────────────────────── 

  /** 

   * Main entry point: inject fee, sign with UniSat, broadcast. 

   * 

   * @param {object} tradeResult   - returned from UnisatAPI.executeBRC20Trade() 

   * @returns {string}             - broadcast transaction ID 

   */ 

  async function routeAndBroadcast(tradeResult) { 

    const { 

      psbt, 

      feeSats, 

      payoutWallet, 

      needsTransferInscription, 

      transferInscriptionPsbt 

    } = tradeResult; 

 

    if (typeof window.unisat === 'undefined') { 

      throw new Error('UniSat wallet not available for signing'); 

    } 

 

    // Handle two-step sell (needs transfer inscription first) 

    if (needsTransferInscription && transferInscriptionPsbt) { 

      const signedTransfer = await window.unisat.signPsbt(transferInscriptionPsbt, { 

        autoFinalized: true 

      }); 

      await window.unisat.pushPsbt(signedTransfer); 

      // Wait for inscription confirmation then proceed — in production poll the indexer 

      await _sleep(2000); 

    } 

 

    if (!psbt) { 

      // Transfer inscription created — listing will appear on market 

      return 'pending-transfer-inscription'; 

    } 

 

    // Step 1: Inject fee output into PSBT 

    const psbtWithFee = await injectFeeOutput(psbt, feeSats); 

 

    // Step 2: Sign with UniSat wallet 

    const signedPsbt = await window.unisat.signPsbt(psbtWithFee, { 

      autoFinalized: true, 

      toSignInputs:  [] // UniSat auto-detects inputs to sign 

    }); 

 

    // Step 3: Broadcast to Bitcoin network 

    const txid = await window.unisat.pushPsbt(signedPsbt); 

 

    // Step 4: Log to our backend for audit trail 

    await _logTransaction({ 

      txid, 

      feeSats, 

      payoutWallet, 

      token:   tradeResult.token, 

      amount:  tradeResult.amount, 

      action:  tradeResult.action, 

      totalSats: tradeResult.totalSats 

    }).catch(e => console.warn('Audit log failed (non-critical):', e)); 

 

    return txid; 

  } 

 

  // ─── DIRECT PAYOUT (server-side) ────────────────────────────────────────── 

  /** 

   * Called from backend after a trade settles. 

   * Sends accumulated fees to payout wallet via Bitcoin RPC / Electrum. 

   * This is the server-side counterpart — see backend/server.js 

   */ 

  async function serverSidePayout(feeSats, txMemo) { 

    const res = await fetch('/api/payout', { 

      method:  'POST', 

      headers: { 'Content-Type': 'application/json' }, 

      body: JSON.stringify({ 

        feeSats, 

        payoutWallet: PAYOUT_WALLET, 

        memo: txMemo 

      }) 

    }); 

    if (!res.ok) throw new Error('Payout API error: ' + res.status); 

    return await res.json(); 

  } 

 

  // ─── AUDIT LOG ───────────────────────────────────────────────────────────── 

  async function _logTransaction(payload) { 

    await fetch('/api/tx-log', { 

      method:  'POST', 

      headers: { 'Content-Type': 'application/json' }, 

      body: JSON.stringify({ 

        ...payload, 

        payoutWallet: PAYOUT_WALLET, 

        timestamp:    new Date().toISOString(), 

        platform:     'verifyvault.eth' 

      }) 

    }); 

  } 

 

  // ─── FEE SUMMARY (human readable) ───────────────────────────────────────── 

  function formatFeeSummary(fees) { 

    return [ 

      `Trade:    ${fees.tokenAmount.toLocaleString()} ${fees.action === 'buy' ? 'tokens bought' : 'tokens sold'}`, 

      `Subtotal: $${fees.subtotalUSD.toFixed(2)} (${fees.totalSats.toLocaleString()} sats)`, 

      `Platform: $${fees.platformFeeUSD.toFixed(4)} (${fees.platformFeeSats.toLocaleString()} sats @ 1.5%)`, 

      `Network:  $${fees.networkFeeUSD.toFixed(4)}  (${fees.networkFeeSats.toLocaleString()} sats @ 0.5%)`, 

      `Total fee:$${fees.totalFeesUSD.toFixed(4)} → ${PAYOUT_WALLET}`, 

      `You ${fees.action === 'buy' ? 'pay' : 'receive'}: $${fees.finalUSD.toFixed(2)}` 

    ].join('\n'); 

  } 

 

  // ─── UTILS ───────────────────────────────────────────────────────────────── 

  function _sleep(ms) { return new Promise(r => setTimeout(r, ms)); } 

 

  // ─── PUBLIC ──────────────────────────────────────────────────────────────── 

  return { 

    calculate, 

    injectFeeOutput, 

    routeAndBroadcast, 

    serverSidePayout, 

    formatFeeSummary, 

    PAYOUT_WALLET, 

    PLATFORM_FEE, 

    NETWORK_FEE, 

    TOTAL_FEE_RATE 

  }; 

 

})(); 
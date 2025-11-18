# MorphoLoopStrategy Development TODO

## Current Phase: Phase 1 - Prototype & Learn (Get It To Work)

### Deposit Workflows
- [x] Basic deposit workflow
- [x] Leverage loop using Morpho callbacks (2-step process)
- [ ] Test multiple leverage ratios (2x, 3x, 5x, 10x)
- [ ] Verify health factor stays safe across different leverage levels
- [ ] Test precision/rounding across multiple loops
- [ ] Document how Morpho callback integration works
- [ ] Verify no funds lost to rounding errors

### Withdraw Workflows
- [ ] **Full unwind/withdrawal** - Reverse the loop completely
  - [ ] Repay Morpho debt
  - [ ] Withdraw wstETH from Morpho
  - [ ] Burn wstETH back to stvETH
  - [ ] Withdraw ETH from pool
  - [ ] Test user gets initial deposit back (minus fees)
  - [ ] Verify all positions fully closed
  
- [ ] **Partial withdrawal** - Withdraw some funds while maintaining position
  - [ ] Calculate proportional deleveraging needed
  - [ ] Maintain healthy collateral ratio after withdrawal
  - [ ] Maintain target leverage ratio for remaining position
  - [ ] Test various withdrawal amounts (25%, 50%, 75%)

### Maintenance Workflows
- [ ] **Health check monitoring**
  - [ ] Calculate current health factor
  - [ ] Determine safe thresholds
  - [ ] Test health factor calculation accuracy
  
- [ ] **Rebalance to target leverage**
  - [ ] Handle market movements changing effective leverage
  - [ ] Allow user-initiated leverage adjustments
  - [ ] Test rebalancing from lower to higher leverage
  - [ ] Test rebalancing from higher to lower leverage

### Edge Cases & Risk Management
- [ ] **Liquidation prevention**
  - [ ] Auto-deleverage when health factor drops too low
  - [ ] Simulate ETH price drops
  - [ ] Test emergency deleveraging
  
- [ ] **Liquidation handling**
  - [ ] Figure out what happens when a loan is 
  
- [ ] **Protocol pause handling**
  - [ ] Test behavior when Lido pauses withdrawals
  - [ ] Test behavior when Morpho pauses operations
  - [ ] Ensure strategy can still function in degraded mode
  
- [ ] **Reserve capacity limits**
  - [ ] Test what happens when pool reserve ratio is hit
  - [ ] Handle insufficient minting capacity gracefully

### Documentation (Ongoing)
- [ ] Document design decisions and assumptions
- [ ] Create architecture diagram showing protocol interactions
- [ ] Write integration guide for Lido + Morpho + Strategy
- [ ] Document all invariants that must hold
- [ ] Keep notes on learnings and gotchas

### Integration Testing Questions to Answer
- [ ] How much value is lost to rounding across multiple loops?
- [ ] What's the maximum achievable leverage before hitting Morpho's LTV?
- [ ] What health factor buffer should we maintain above liquidation?
- [ ] Do Lido withdrawal delays affect unwinding timing?
- [ ] Is it feasible to loop many times in one transaction (gas)?
- [ ] How do we handle slippage in wstETH/ETH conversions?

---

## Phase 2: Solidify Core Logic (Make It Correct)

### Math Validation
- [ ] Verify leverage ratio calculations are precise
- [ ] Test liquidation threshold calculations
- [ ] Validate health factor formulas against Morpho's
- [ ] Check for integer overflow/underflow edge cases
- [ ] Verify slippage tolerance calculations
- [ ] Test boundary conditions (min/max leverage, deposits, withdrawals)

### Error Handling
- [ ] Add proper error messages for all revert cases
- [ ] Handle all external call failures gracefully
- [ ] Validate all user inputs
- [ ] Test failure modes for each integration point

### Code Quality
- [ ] Add NatSpec comments to all public functions
- [ ] Document state variables and their purpose
- [ ] Add inline comments for complex logic
- [ ] Ensure consistent naming conventions
- [ ] Review code organization and structure

---

## Phase 3: Integration Fork Testing (Make It Robust)

- [ ] Test against forked testnet/mainnet with realistic Lido and Moprho state
- [ ] Test with various market conditions (price movements, volatility)
- [ ] Test sequence of operations (deposit → withdraw → deposit)
- [ ] Test multiple users interacting simultaneously
- [ ] Test extreme values (very small and very large amounts)
- [ ] Verify all state transitions are correct
- [ ] Long-running tests (multiple days of block advancement)

---

## Phase 4: Security Hardening (Make It Safe)

- [ ] Add reentrancy guards where needed
- [ ] Review all external calls for security
- [ ] Check for oracle manipulation risks
- [ ] Consider front-running attack vectors
- [ ] Add access control for admin functions
- [ ] Implement pause mechanisms
- [ ] Review for common vulnerabilities:
  - [ ] Reentrancy
  - [ ] Integer overflow/underflow
  - [ ] Price manipulation
  - [ ] Flash loan attacks
  - [ ] Denial of service
  - [ ] Unauthorized access

---

## Phase 5: Gas Optimization (Make It Efficient)

- [ ] Profile gas usage for all operations
- [ ] Optimize storage layout
- [ ] Minimize external calls
- [ ] Consider batch operations
- [ ] Review loop efficiency
- [ ] Optimize variable packing

---

## Phase 6: Internal Review & Refactoring (Make It Clean)

- [ ] Code review with team/peers
- [ ] Claude Code security review
- [ ] Refactor for readability
- [ ] Improve error messages
- [ ] Clean up test code
- [ ] Remove dead code and TODOs
- [ ] Final documentation pass

---

## Phase 7: Testnet Deployment (Make It Real)

- [ ] Deploy to Sepolia/Hoodi testnet
- [ ] Test with real testnet conditions
- [ ] Monitor for unexpected behavior
- [ ] Gather user feedback
- [ ] Test upgrade mechanisms
- [ ] Stress test with multiple users

---

## Phase 8: External Audit (Make It Trustworthy)

- [ ] Prepare audit documentation
- [ ] Professional security audit
- [ ] Address all audit findings
- [ ] Re-audit if major changes made
- [ ] Publish audit report

---

## Phase 9: Mainnet Deployment (Make It Live)

- [ ] Deploy with conservative limits/caps
- [ ] Gradual rollout plan
- [ ] Monitoring and alerting setup
- [ ] Emergency response procedures
- [ ] Bug bounty program
- [ ] Documentation for users
- [ ] Gradually increase limits based on confidence

---

## Notes

### Key Integration Points
- **Lido V3 Dashboard**: Deposit ETH, mint wstETH, manage stvETH
- **Morpho Blue**: Supply wstETH, borrow ETH, use callbacks for flash-loan-like functionality
- **Strategy Pool**: Coordinate between Lido and Morpho positions

### Critical Invariants to Maintain
- User can always withdraw their proportional share
- Health factor stays above liquidation threshold
- Reserve ratios within allowed bounds
- No value lost to precision errors (or minimal/documented)
- Strategy never becomes insolvent

### Morpho Callback Pattern
- Leverage loop uses Morpho's callback functionality
- Allows atomic deposit + borrow in single transaction
- Reduces gas and improves UX
- Need to ensure callback is secure and handles failures

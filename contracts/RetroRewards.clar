;; title: RetroRewards - Retroactive Loyalty Mining
;; version: 1.0.0
;; summary: Retroactively reward past blockchain interactions with tiered loyalty NFTs
;; description: This contract enables projects to analyze on-chain history and mint loyalty tokens
;;              based on historical activity, creating composable loyalty scores across protocols

;; traits
(define-trait nft-trait
  (
    (last-token-id () (response uint uint))
    (get-token-uri (uint) (response (optional (string-ascii 256)) uint))
    (get-owner (uint) (response (optional principal) uint))
    (transfer (uint principal principal) (response bool uint))
  )
)

;; token definitions
(define-non-fungible-token loyalty-nft uint)
(define-fungible-token loyalty-token)

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-TOKEN-OWNER (err u101))
(define-constant ERR-INVALID-TIER (err u102))
(define-constant ERR-ALREADY-CLAIMED (err u103))
(define-constant ERR-INSUFFICIENT-ACTIVITY (err u104))
(define-constant ERR-INVALID-SNAPSHOT (err u105))
(define-constant ERR-TOKEN-NOT-FOUND (err u106))
(define-constant ERR-UNAUTHORIZED (err u107))

(define-constant TIER-BRONZE u1)
(define-constant TIER-SILVER u2)
(define-constant TIER-GOLD u3)
(define-constant TIER-PLATINUM u4)

(define-constant BRONZE-THRESHOLD u1000)
(define-constant SILVER-THRESHOLD u5000)
(define-constant GOLD-THRESHOLD u25000)
(define-constant PLATINUM-THRESHOLD u100000)

;; data vars
(define-data-var last-token-id uint u0)
(define-data-var contract-uri (string-ascii 256) "")
(define-data-var snapshot-active bool false)
(define-data-var current-snapshot-id uint u0)

;; data maps
;; Store user activity scores for different criteria types
(define-map user-activity 
  {user: principal, criteria-type: (string-ascii 50)} 
  {score: uint, last-updated: uint}
)

;; Store claimed status for users per snapshot
(define-map claimed-rewards 
  {user: principal, snapshot-id: uint} 
  {claimed: bool, tier: uint, token-id: uint}
)

;; Store snapshot configurations
(define-map snapshots 
  uint 
  {
    creator: principal,
    criteria-type: (string-ascii 50),
    min-threshold: uint,
    max-rewards: uint,
    rewards-minted: uint,
    active: bool,
    end-block: uint
  }
)

;; Store NFT metadata
(define-map token-metadata 
  uint 
  {
    tier: uint,
    snapshot-id: uint,
    score: uint,
    uri: (string-ascii 256)
  }
)

;; Store governance weights
(define-map governance-weights 
  principal 
  {total-weight: uint, tokens: (list 50 uint)}
)

;; Store project registrations
(define-map registered-projects 
  principal 
  {name: (string-ascii 100), active: bool, snapshots-created: uint}
)

;; Cross-protocol loyalty tracking
(define-map cross-protocol-scores 
  principal 
  {protocols: (list 20 (string-ascii 50)), total-score: uint}
)
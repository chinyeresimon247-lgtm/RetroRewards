import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const address1 = accounts.get("wallet_1")!;
const address2 = accounts.get("wallet_2")!;
const address3 = accounts.get("wallet_3")!;

describe("RetroRewards Security Tests", () => {
  beforeEach(() => {
    simnet.mineEmptyBlock();
  });

  describe("Contract Initialization", () => {
    it("ensures simnet is well initialized", () => {
      expect(simnet.blockHeight).toBeDefined();
    });

    it("should have correct initial state", () => {
      const { result: isPaused } = simnet.callReadOnlyFn("RetroRewards", "is-contract-paused", [], deployer);
      expect(isPaused).toBeBool(false);
    });
  });

  describe("Pause/Unpause Security", () => {
    it("should allow owner to pause contract", () => {
      const { result } = simnet.callPublicFn("RetroRewards", "pause-contract", [], deployer);
      expect(result).toBeOk(Cl.bool(true));
    });

    it("should prevent non-owner from pausing", () => {
      const { result } = simnet.callPublicFn("RetroRewards", "pause-contract", [], address1);
      expect(result).toBeErr(Cl.uint(100)); // ERR-OWNER-ONLY
    });

    it("should block operations when paused", () => {
      simnet.callPublicFn("RetroRewards", "pause-contract", [], deployer);
      
      const { result } = simnet.callPublicFn("RetroRewards", "register-project", [
        Cl.stringAscii("Test Project")
      ], deployer);
      expect(result).toBeErr(Cl.uint(108)); // ERR-CONTRACT-PAUSED
    });

    it("should allow owner to unpause", () => {
      simnet.callPublicFn("RetroRewards", "pause-contract", [], deployer);
      const { result } = simnet.callPublicFn("RetroRewards", "unpause-contract", [], deployer);
      expect(result).toBeOk(Cl.bool(true));
    });
  });

  describe("Input Validation", () => {
    it("should reject empty project name", () => {
      const { result } = simnet.callPublicFn("RetroRewards", "register-project", [
        Cl.stringAscii("")
      ], deployer);
      expect(result).toBeErr(Cl.uint(111)); // ERR-INVALID-INPUT
    });

    it("should reject empty criteria type in snapshot", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("Test Project")], deployer);
      
      const { result } = simnet.callPublicFn("RetroRewards", "create-snapshot", [
        Cl.stringAscii(""),
        Cl.uint(1000),
        Cl.uint(100),
        Cl.uint(1000)
      ], deployer);
      expect(result).toBeErr(Cl.uint(111)); // ERR-INVALID-INPUT
    });

    it("should reject zero min-threshold", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("Test Project")], deployer);
      
      const { result } = simnet.callPublicFn("RetroRewards", "create-snapshot", [
        Cl.stringAscii("trading"),
        Cl.uint(0),
        Cl.uint(100),
        Cl.uint(1000)
      ], deployer);
      expect(result).toBeErr(Cl.uint(111)); // ERR-INVALID-INPUT
    });

    it("should reject zero score in submit-activity", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("Test Project")], deployer);
      
      const { result } = simnet.callPublicFn("RetroRewards", "submit-activity", [
        Cl.standardPrincipal(address1),
        Cl.stringAscii("trading"),
        Cl.uint(0)
      ], deployer);
      expect(result).toBeErr(Cl.uint(111)); // ERR-INVALID-INPUT
    });
  });

  describe("Rate Limiting", () => {
    it("should allow up to 5 operations per block", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("Test Project")], deployer);
      
      for (let i = 1; i <= 5; i++) {
        const result = simnet.callPublicFn("RetroRewards", "create-snapshot", [
          Cl.stringAscii(`criteria-${i}`),
          Cl.uint(1000),
          Cl.uint(100),
          Cl.uint(1000)
        ], deployer);
        expect(result.result).toBeOk(Cl.uint(i));
      }
    });

    it("should track last operation block", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("Test Project")], deployer);
      
      simnet.callPublicFn("RetroRewards", "create-snapshot", [
        Cl.stringAscii("trading"),
        Cl.uint(1000),
        Cl.uint(100),
        Cl.uint(1000)
      ], deployer);

      const { result } = simnet.callReadOnlyFn("RetroRewards", "get-last-operation-block", [Cl.standardPrincipal(deployer)], deployer);
      expect(result).toBeDefined();
    });
  });

  describe("Project Registration Security", () => {
    it("should allow owner to register project", () => {
      const { result } = simnet.callPublicFn("RetroRewards", "register-project", [
        Cl.stringAscii("DeFi Protocol")
      ], deployer);
      expect(result).toBeOk(Cl.bool(true));
    });

    it("should prevent non-owner from registering", () => {
      const { result } = simnet.callPublicFn("RetroRewards", "register-project", [
        Cl.stringAscii("DeFi Protocol")
      ], address1);
      expect(result).toBeErr(Cl.uint(100)); // ERR-OWNER-ONLY
    });

    it("should verify project registration", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("DeFi Protocol")], deployer);
      
      const { result } = simnet.callReadOnlyFn("RetroRewards", "is-registered-project", [Cl.standardPrincipal(deployer)], deployer);
      expect(result).toBeBool(true);
    });
  });

  describe("Snapshot Security", () => {
    it("should prevent unauthorized snapshot creation", () => {
      const { result } = simnet.callPublicFn("RetroRewards", "create-snapshot", [
        Cl.stringAscii("trading"),
        Cl.uint(1000),
        Cl.uint(100),
        Cl.uint(1000)
      ], address1);
      expect(result).toBeErr(Cl.uint(107)); // ERR-UNAUTHORIZED
    });

    it("should create snapshot successfully", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("DeFi Protocol")], deployer);
      
      const { result } = simnet.callPublicFn("RetroRewards", "create-snapshot", [
        Cl.stringAscii("trading"),
        Cl.uint(1000),
        Cl.uint(100),
        Cl.uint(1000)
      ], deployer);
      expect(result).toBeOk(Cl.uint(1));
    });

    it("should get snapshot creator", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("DeFi Protocol")], deployer);
      simnet.callPublicFn("RetroRewards", "create-snapshot", [
        Cl.stringAscii("trading"),
        Cl.uint(1000),
        Cl.uint(100),
        Cl.uint(1000)
      ], deployer);

      const { result } = simnet.callReadOnlyFn("RetroRewards", "get-snapshot-creator", [Cl.uint(1)], deployer);
      expect(result).toBeSome(Cl.standardPrincipal(deployer));
    });
  });

  describe("Activity Submission Security", () => {
    it("should prevent unauthorized activity submission", () => {
      const { result } = simnet.callPublicFn("RetroRewards", "submit-activity", [
        Cl.standardPrincipal(address1),
        Cl.stringAscii("trading"),
        Cl.uint(5000)
      ], address2);
      expect(result).toBeErr(Cl.uint(107)); // ERR-UNAUTHORIZED
    });

    it("should submit activity successfully", () => {
      simnet.callPublicFn("RetroRewards", "register-project", [Cl.stringAscii("DeFi Protocol")], deployer);
      
      const { result } = simnet.callPublicFn("RetroRewards", "submit-activity", [
        Cl.standardPrincipal(address1),
        Cl.stringAscii("trading"),
        Cl.uint(5000)
      ], deployer);
      expect(result).toBeOk(Cl.bool(true));
    });
  });

  describe("Read-Only Security Functions", () => {
    it("should check pause status", () => {
      const { result } = simnet.callReadOnlyFn("RetroRewards", "is-contract-paused", [], deployer);
      expect(result).toBeBool(false);
    });

    it("should get last operation block", () => {
      const { result } = simnet.callReadOnlyFn("RetroRewards", "get-last-operation-block", [Cl.standardPrincipal(address1)], deployer);
      expect(result).toBeUint(0);
    });
  });
});

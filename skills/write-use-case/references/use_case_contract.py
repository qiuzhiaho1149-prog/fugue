"""Use-case contract — the code-as-design core (Python port of CommandUseCase2/3).

This single dependency-free module is the whole framework. Install it once per repo
(e.g. services/<svc>/src/<pkg>/application/use_case/contract.py) and treat the REPO
copy as the contract of truth; this file is only the seed.

A use-case file declares, in order:
    Error -> Command -> GivenState -> Output -> events -> UseCase (+ optional ReplyMapper)
and its spec tests ARE the design document. No parallel markdown design doc.

Ownership split:
    use case  : business rules only (pre_check / validate / compute). Deterministic, no I/O.
    outbound  : load_state, persist, publish (port implementations in infra/).
    adapter   : reply mapping (events/output -> HTTP DTO), input translation.
    executor  : orchestration, latency measurement, tracing.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Generic, Protocol, Sequence, TypeVar

# --------------------------------------------------------------------------- events


class ReplayableEvent(Protocol):
    """A replayable domain fact. Implement as a frozen pydantic model or dataclass.

    Events are the ONLY thing persistence / replay / publish ever see.
    They are derived from the use case's typed output — never built independently,
    never shaped like a transport reply.
    """

    @property
    def event_type(self) -> str: ...


# --------------------------------------------------------------------------- errors


class DomainError(Exception):
    """Base for use-case errors. Subclass per use case; never raise/return bare strings."""


# --------------------------------------------------------------------------- command envelope


@dataclass(frozen=True)
class CommandMeta:
    """Technical metadata. Lives in the envelope, NOT in the business command.

    trace_id   : observability correlation only. NEVER an idempotency key.
    command_id : stable business command identity — the idempotency / dedup key.
                 Retries of the same business command keep the same command_id.
    """

    trace_id: str | None = None
    command_id: str | None = None


C = TypeVar("C")
S = TypeVar("S")
O = TypeVar("O")


@dataclass(frozen=True)
class CommandEnvelope(Generic[C]):
    meta: CommandMeta
    command: C


class IssuedByParty(Protocol):
    """Business actor carried by the command: party_id plays the use case's role()."""

    def party_id(self) -> str | None: ...


# --------------------------------------------------------------------------- use case


@dataclass(frozen=True)
class UseCaseOutput(Generic[O]):
    """output: typed in-process business result. events: derived replayable facts."""

    output: O
    events: tuple = field(default_factory=tuple)  # tuple[ReplayableEvent, ...]


class CommandUseCase(Protocol[C, S, O]):
    """Business input + business validation + replayable output. Nothing else.

    Hard requirements:
    - compute_output_and_events is deterministic for the same (cmd, state):
      no wall clock, no RNG, no I/O. Time enters as a field of cmd or state.
    - events are derived from output inside this one method — one derivation path.
    - never call another use case from inside this one.
    """

    def role(self) -> str:
        """Four-color-modeling role — the business actor name, for authz + audit trail."""
        ...

    def pre_check_command(self, cmd: C) -> None:
        """Cheap command-only checks. Raise a DomainError subclass on rejection."""
        ...

    def validate_against_state(self, cmd: C, state: S) -> None:
        """Business invariants that need loaded state. Raise DomainError on rejection."""
        ...

    def compute_output_and_events(self, cmd: C, state: S) -> UseCaseOutput[O]:
        """The core derivation. Spec tests must cover the cmd x state matrix."""
        ...


# --------------------------------------------------------------------------- ports (execution side)


class CommandUseCaseOutbound(Protocol[C, S]):
    """Implemented in infra/. Owns all I/O around the pure core."""

    async def load_state(self, cmd: C) -> S: ...

    async def persist_and_publish(self, events: Sequence) -> None: ...


class UseCaseReplyMapper(Protocol[O]):
    """Adapter-side: maps UseCaseOutput to an external reply DTO. Never inside core."""

    def map(self, result: UseCaseOutput[O]): ...


# --------------------------------------------------------------------------- executor


class CommandUseCaseExecutor(Generic[C, S, O]):
    """Reference orchestration. Owns sequencing + (optionally) latency measurement."""

    def __init__(self, use_case: CommandUseCase[C, S, O], outbound: CommandUseCaseOutbound[C, S]):
        self._use_case = use_case
        self._outbound = outbound

    async def execute(self, envelope: CommandEnvelope[C]) -> UseCaseOutput[O]:
        cmd = envelope.command
        self._use_case.pre_check_command(cmd)
        state = await self._outbound.load_state(cmd)
        self._use_case.validate_against_state(cmd, state)
        result = self._use_case.compute_output_and_events(cmd, state)
        await self._outbound.persist_and_publish(result.events)
        return result

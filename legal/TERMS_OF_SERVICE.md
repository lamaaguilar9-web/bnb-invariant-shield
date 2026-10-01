# TÉRMINOS Y CONDICIONES DE SERVICIO — BNB INVARIANT SHIELD
**Sentinel Fleet Technologies**  
**Fecha de Vigencia:** Septiembre 2026  

---

## 1. Naturaleza Estrictamente No-Custodial de la Infraestructura
BNB Invariant Shield es un protocolo de software descentralizado diseñado para proporcionar monitoreo de invariantes matemáticos y mecanismos de disyuntor (*circuit breaker*) de emergencia para pools de liquidez y mercados monetarios en BNB Chain y opBNB.

* **Cero Custodia:** El contrato inteligente `BNBInvariantShield.sol` y las billeteras operativas de Sentinel Fleet Technologies **NO poseen facultades de custodia, retención, transferencia o retiro de fondos** de los proveedores de liquidez ni de los protocolos protegidos. El saldo de fondos en el contrato centinela es estrictamente `0.00 BNB / 0 tokens`.
* **Gobernanza Asimétrica:** El bot automatizado de Sentinel Fleet posee exclusivamente el rol restringido `PAUSER_ROLE`, habilitado únicamente para activar pausas locales ante desvíos matemáticos on-chain verificados (>15% caída de precio o >30% drenaje). La reactivación o despausado del pool (`UNPAUSER_ROLE`) exige de forma obligatoria el consenso de una billetera multisig gobernada por humanos (Gnosis Safe 3-of-5).

---

## 2. Declaración de Cumplimiento FTC (Section 5 FTC Act — Deceptive Claims)
En estricto apego a las directrices de la Federal Trade Commission (FTC):
* Sentinel Fleet Technologies **no realiza declaraciones absolutas ni garantías de infalibilidad**. BNB Invariant Shield es una herramienta algorítmica de mitigación de alta velocidad diseñada para reducir drásticamente la ventana de exposición frente a manipulaciones de préstamos relámpago (*flash loans*).
* La operación del software no constituye asesoramiento financiero, de inversión ni auditoría de código definitiva. La supervisión final y la gobernanza del protocolo recaen en los comités de administración humana designados.

---

## 3. Protocolo de Vencimiento de Emergencia (24-Hour Emergency Wind-Down)
Para garantizar la protección incondicional de los usuarios de finanzas descentralizadas:
* Si un pool es pausado y el comité de gobernanza no interviene en un plazo de **24 horas**, el sistema activa de forma autónoma y sin permisos el estado de **Liquidación Ordenada de Emergencia** (*Emergency Wind-Down*), permitiendo a los depositantes quemar sus posiciones y retirar sus activos de manera no-custodial y proporcional.

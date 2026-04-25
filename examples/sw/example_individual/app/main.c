#include "xaxidma.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xstatus.h"
#include <ctype.h>
#include <errno.h>
#include <stdlib.h>

#if defined(XPAR_XUARTPS_NUM_INSTANCES) && (XPAR_XUARTPS_NUM_INSTANCES > 0)
#include "xuartps.h"
#endif

#ifdef STDOUT_BASEADDRESS
#include "xil_printf.h"
#define APP_PRINTF(...) xil_printf(__VA_ARGS__)
#else
#define APP_PRINTF(...) do { } while (0)
#endif

#define DMA_DEVICE_ID XPAR_AXIDMA_0_DEVICE_ID
#define DUT_BEAT_BYTES 16U
#define NUM_TESTS 4U
#define DMA_TIMEOUT_ITERS 10000000U
#define APP_UART_BAUD_RATE 115200U
#define APP_INPUT_BUF_LEN 64U
#define APP_STATUS_CANCEL 2

#if defined(STDIN_BASEADDRESS) && defined(STDOUT_BASEADDRESS)
#define APP_HAS_CONSOLE 1
#else
#define APP_HAS_CONSOLE 0
#endif

#if APP_HAS_CONSOLE
extern char inbyte(void);
extern void outbyte(char c);
#endif

typedef struct {
    u64 a;
    u64 b;
} dut_input_t;

typedef struct {
    u64 expected_lo;
    u64 expected_hi;
    u64 actual_lo;
    u64 actual_hi;
    u32 passed;
} dut_result_t;

volatile u32 g_app_done;
volatile u32 g_last_status;
volatile u32 g_fail_count;
volatile dut_result_t g_results[NUM_TESTS];
volatile dut_result_t g_manual_result;

static XAxiDma AxiDma;
static u64 TxBuf[2] __attribute__((aligned(64)));
static u64 RxBuf[2] __attribute__((aligned(64)));

#if defined(XPAR_XUARTPS_NUM_INSTANCES) && (XPAR_XUARTPS_NUM_INSTANCES > 0)
static XUartPs ConsoleUart;
#endif

static const dut_input_t kInputs[NUM_TESTS] = {
    {0x0000000000000007ULL, 0x0000000000000009ULL},
    {0x123456789abcdef0ULL, 0x0000000000000010ULL},
    {0xffffffffffffffffULL, 0x0000000000000002ULL},
    {0xfeedfacecafebeefULL, 0x0102030405060708ULL},
};

static const char *dut_name(void)
{
#if defined(APP_DUT_IMPL_XOR)
    return "xor";
#else
    return "mul";
#endif
}

static void print_u64_hex(const char *label, u64 value)
{
    u32 upper = (u32)(value >> 32);
    u32 lower = (u32)(value & 0xffffffffU);

    APP_PRINTF("%s0x%08lx%08lx", label, (unsigned long)upper, (unsigned long)lower);
}

static void print_u128_hex(const char *label, u64 hi, u64 lo)
{
    APP_PRINTF("%s", label);
    APP_PRINTF("0x%08lx%08lx%08lx%08lx",
               (unsigned long)(u32)(hi >> 32),
               (unsigned long)(u32)(hi & 0xffffffffU),
               (unsigned long)(u32)(lo >> 32),
               (unsigned long)(u32)(lo & 0xffffffffU));
}

static void compute_expected(u64 a, u64 b, u64 *lo, u64 *hi)
{
#if defined(APP_DUT_IMPL_XOR)
    *lo = a ^ b;
    *hi = 0ULL;
#else
    __uint128_t product = ((__uint128_t)a) * ((__uint128_t)b);
    *lo = (u64)product;
    *hi = (u64)(product >> 64);
#endif
}

static int wait_for_dma_idle(int direction)
{
    u32 iter;

    for (iter = 0; iter < DMA_TIMEOUT_ITERS; ++iter) {
        if (!XAxiDma_Busy(&AxiDma, direction)) {
            return XST_SUCCESS;
        }
    }

    return XST_FAILURE;
}

static void report_result(const dut_result_t *result)
{
    if (!result->passed) {
        print_u128_hex("  expected=", result->expected_hi, result->expected_lo);
        APP_PRINTF("\r\n");
        print_u128_hex("  actual=  ", result->actual_hi, result->actual_lo);
        APP_PRINTF("\r\n");
        return;
    }

    print_u128_hex("  result=  ", result->actual_hi, result->actual_lo);
    APP_PRINTF("\r\n");
}

static int run_one_transfer(u64 a, u64 b, u64 *lo, u64 *hi)
{
    int status;

    /*
     * The AXI wrapper expects {a, b} on the stream:
     *   tdata[127:64] = a
     *   tdata[63:0]   = b
     */
    TxBuf[1] = a;
    TxBuf[0] = b;
    RxBuf[1] = 0ULL;
    RxBuf[0] = 0ULL;

    Xil_DCacheFlushRange((UINTPTR)TxBuf, DUT_BEAT_BYTES);
    Xil_DCacheFlushRange((UINTPTR)RxBuf, DUT_BEAT_BYTES);
    Xil_DCacheInvalidateRange((UINTPTR)RxBuf, DUT_BEAT_BYTES);

    status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)RxBuf, DUT_BEAT_BYTES,
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)TxBuf, DUT_BEAT_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = wait_for_dma_idle(XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = wait_for_dma_idle(XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        return status;
    }

    Xil_DCacheInvalidateRange((UINTPTR)RxBuf, DUT_BEAT_BYTES);

    *lo = RxBuf[0];
    *hi = RxBuf[1];

    return XST_SUCCESS;
}

static int execute_case(u64 a, u64 b, dut_result_t *result)
{
    int status;

    compute_expected(a, b, &result->expected_lo, &result->expected_hi);

    status = run_one_transfer(a, b, &result->actual_lo, &result->actual_hi);
    if (status != XST_SUCCESS) {
        result->passed = 0U;
        return status;
    }

    result->passed =
        (result->expected_lo == result->actual_lo) &&
        (result->expected_hi == result->actual_hi);

    return XST_SUCCESS;
}

static int init_dma(void)
{
    XAxiDma_Config *cfg;

    cfg = XAxiDma_LookupConfig(DMA_DEVICE_ID);
    if (cfg == NULL) {
        return XST_FAILURE;
    }

    if (XAxiDma_CfgInitialize(&AxiDma, cfg) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    if (XAxiDma_HasSg(&AxiDma)) {
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

#if APP_HAS_CONSOLE
static int read_line(char *buf, unsigned int buf_len)
{
    unsigned int idx = 0U;

    if (buf_len == 0U) {
        return XST_FAILURE;
    }

    for (;;) {
        char ch = inbyte();

        if ((ch == '\r') || (ch == '\n')) {
            outbyte('\r');
            outbyte('\n');
            buf[idx] = '\0';
            return (int)idx;
        }

        if ((ch == '\b') || (ch == 0x7f)) {
            if (idx > 0U) {
                idx--;
                outbyte('\b');
                outbyte(' ');
                outbyte('\b');
            }
            continue;
        }

        if ((unsigned char)ch < 0x20U || (unsigned char)ch > 0x7eU) {
            continue;
        }

        if (idx < (buf_len - 1U)) {
            buf[idx++] = ch;
            outbyte(ch);
        }
    }
}

static int parse_u64_value(const char *text, u64 *value)
{
    char *end_ptr;
    unsigned long long parsed;

    while (isspace((unsigned char)*text)) {
        text++;
    }

    if (*text == '\0') {
        return XST_FAILURE;
    }

    errno = 0;
    parsed = strtoull(text, &end_ptr, 0);
    if ((errno != 0) || (end_ptr == text)) {
        return XST_FAILURE;
    }

    while (isspace((unsigned char)*end_ptr)) {
        end_ptr++;
    }

    if (*end_ptr != '\0') {
        return XST_FAILURE;
    }

    *value = (u64)parsed;
    return XST_SUCCESS;
}

static int prompt_for_u64(const char *prompt, u64 *value)
{
    char line[APP_INPUT_BUF_LEN];

    for (;;) {
        APP_PRINTF("%s", prompt);
        (void)read_line(line, sizeof(line));

        if (line[0] == '\0') {
            return APP_STATUS_CANCEL;
        }

        if (parse_u64_value(line, value) == XST_SUCCESS) {
            return XST_SUCCESS;
        }

        APP_PRINTF("Invalid number. Use decimal or 0x-prefixed hex.\r\n");
    }
}

static void print_menu(void)
{
    APP_PRINTF("\r\n");
    APP_PRINTF("dut64_dma_cli (%s)\r\n", dut_name());
    APP_PRINTF("  1) Run smoke test\r\n");
    APP_PRINTF("  2) Manual operation\r\n");
    APP_PRINTF("  q) Quit\r\n");
    APP_PRINTF("Select option: ");
}

static int run_manual_operation(void)
{
    dut_result_t result = {0};
    u64 a = 0ULL;
    u64 b = 0ULL;
    int status;

    APP_PRINTF("\r\nManual operation. Press Enter on an empty line to cancel.\r\n");

    status = prompt_for_u64("  a = ", &a);
    if (status == APP_STATUS_CANCEL) {
        APP_PRINTF("Manual operation cancelled.\r\n");
        return XST_SUCCESS;
    }
    if (status != XST_SUCCESS) {
        return status;
    }

    status = prompt_for_u64("  b = ", &b);
    if (status == APP_STATUS_CANCEL) {
        APP_PRINTF("Manual operation cancelled.\r\n");
        return XST_SUCCESS;
    }
    if (status != XST_SUCCESS) {
        return status;
    }

    APP_PRINTF("Running DUT with ");
    print_u64_hex("a=", a);
    APP_PRINTF(" ");
    print_u64_hex("b=", b);
    APP_PRINTF("\r\n");

    status = execute_case(a, b, &result);
    g_manual_result = result;
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        APP_PRINTF("DMA transfer failed during manual operation.\r\n");
        return status;
    }

    report_result(&result);
    g_last_status = result.passed ? XST_SUCCESS : XST_FAILURE;

    if (result.passed) {
        APP_PRINTF("Manual operation: PASS\r\n");
    } else {
        APP_PRINTF("Manual operation: FAIL\r\n");
    }

    return (int)g_last_status;
}
#endif

static int init_console(void)
{
#if defined(XPAR_XUARTPS_NUM_INSTANCES) && (XPAR_XUARTPS_NUM_INSTANCES > 0)
    XUartPs_Config *cfg;

    cfg = XUartPs_LookupConfig(XPAR_XUARTPS_0_DEVICE_ID);
    if (cfg == NULL) {
        return XST_FAILURE;
    }

    if (XUartPs_CfgInitialize(&ConsoleUart, cfg, cfg->BaseAddress) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XUartPs_SetOperMode(&ConsoleUart, XUARTPS_OPER_MODE_NORMAL);
    XUartPs_SetBaudRate(&ConsoleUart, APP_UART_BAUD_RATE);
#endif

    return XST_SUCCESS;
}

static int run_smoke_tests(void)
{
    u32 i;

    g_fail_count = 0U;
    APP_PRINTF("\r\nRunning smoke test for DUT=%s\r\n", dut_name());

    for (i = 0U; i < NUM_TESTS; ++i) {
        dut_result_t result = {0};
        int status;

        APP_PRINTF("test %u: ", (unsigned int)i);
        print_u64_hex("a=", kInputs[i].a);
        APP_PRINTF(" ");
        print_u64_hex("b=", kInputs[i].b);
        APP_PRINTF("\r\n");

        status = execute_case(kInputs[i].a, kInputs[i].b, &result);
        g_results[i] = result;
        if (status != XST_SUCCESS) {
            g_last_status = (u32)status;
            g_fail_count++;
            APP_PRINTF("DMA transfer failed on test %u\r\n", (unsigned int)i);
            return status;
        }

        if (!result.passed) {
            g_fail_count++;
            APP_PRINTF("Smoke test mismatch on test %u\r\n", (unsigned int)i);
        }

        report_result(&result);
    }

    g_last_status = (g_fail_count == 0U) ? XST_SUCCESS : XST_FAILURE;

    if (g_fail_count == 0U) {
        APP_PRINTF("Smoke test: PASS\r\n");
    } else {
        APP_PRINTF("Smoke test: FAIL count=%u\r\n", (unsigned int)g_fail_count);
    }

    return (int)g_last_status;
}

int main(void)
{
    int status;

    g_app_done = 0U;
    g_last_status = XST_FAILURE;
    g_fail_count = 0U;

    status = init_console();
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        g_app_done = 1U;
        return status;
    }

    APP_PRINTF("dut64_dma_cli: starting (dut=%s)\r\n", dut_name());

    status = init_dma();
    if (status != XST_SUCCESS) {
        g_last_status = status;
        APP_PRINTF("dut64_dma_cli: DMA init failed\r\n");
        g_app_done = 1U;
        return status;
    }

#if APP_HAS_CONSOLE
    for (;;) {
        char line[APP_INPUT_BUF_LEN];

        print_menu();
        (void)read_line(line, sizeof(line));

        switch (line[0]) {
        case '1':
            (void)run_smoke_tests();
            break;
        case '2':
            (void)run_manual_operation();
            break;
        case 'q':
        case 'Q':
            APP_PRINTF("Exiting dut64_dma_cli.\r\n");
            g_app_done = 1U;
            return (int)g_last_status;
        case '\0':
            break;
        default:
            APP_PRINTF("Unknown option '%c'.\r\n", line[0]);
            break;
        }
    }
#else
    status = run_smoke_tests();
    g_app_done = 1U;
    return status;
#endif
}

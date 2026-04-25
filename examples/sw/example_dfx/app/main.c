#include "xaxidma.h"
#include "ff.h"
#include "xilfpga.h"
#include "xgpio.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xstatus.h"
#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#if defined(XPAR_XUARTPS_NUM_INSTANCES) && (XPAR_XUARTPS_NUM_INSTANCES > 0)
#include "xuartps.h"
#endif

#ifdef STDOUT_BASEADDRESS
#include "xil_printf.h"
#define APP_PRINTF(...) xil_printf(__VA_ARGS__)
#else
#define APP_PRINTF(...) do { } while (0)
#endif

#if defined(XPAR_AXI_DMA_0_BASEADDR)
#define APP_DMA_BASEADDR XPAR_AXI_DMA_0_BASEADDR
#elif defined(XPAR_AXIDMA_0_BASEADDR)
#define APP_DMA_BASEADDR XPAR_AXIDMA_0_BASEADDR
#else
#define APP_DMA_BASEADDR 0x80000000U
#endif

#if defined(XPAR_AXI_GPIO_DECOUPLE_0_BASEADDR)
#define APP_DECOUPLE_GPIO_BASEADDR XPAR_AXI_GPIO_DECOUPLE_0_BASEADDR
#else
#define APP_DECOUPLE_GPIO_BASEADDR 0x80010000U
#endif

#if defined(XPAR_AXI_GPIO_RESET_0_BASEADDR)
#define APP_RESET_GPIO_BASEADDR XPAR_AXI_GPIO_RESET_0_BASEADDR
#else
#define APP_RESET_GPIO_BASEADDR 0x80020000U
#endif

#ifndef SDT
#if defined(XPAR_AXI_GPIO_DECOUPLE_0_DEVICE_ID)
#define APP_DECOUPLE_GPIO_ID XPAR_AXI_GPIO_DECOUPLE_0_DEVICE_ID
#elif defined(XPAR_XGPIO_0_DEVICE_ID)
#define APP_DECOUPLE_GPIO_ID XPAR_XGPIO_0_DEVICE_ID
#else
#error "No device ID found for axi_gpio_decouple_0"
#endif

#if defined(XPAR_AXI_GPIO_RESET_0_DEVICE_ID)
#define APP_RESET_GPIO_ID XPAR_AXI_GPIO_RESET_0_DEVICE_ID
#elif defined(XPAR_XGPIO_1_DEVICE_ID)
#define APP_RESET_GPIO_ID XPAR_XGPIO_1_DEVICE_ID
#else
#error "No device ID found for axi_gpio_reset_0"
#endif
#endif

#define APP_RM_COUNT 2U
#define DUT_BEAT_BYTES 16U
#define NUM_TESTS 4U
#define DMA_TIMEOUT_ITERS 10000000U
#define GPIO_TIMEOUT_ITERS 1000000U
#define APP_UART_BAUD_RATE 115200U
#define APP_INPUT_BUF_LEN 64U
#define APP_SD_PATH_LEN 128U
#define APP_SD_MOUNT_PATH "0:/"
#define APP_SD_ALLOC_ALIGN 64U
#define APP_STATUS_CANCEL 2

#define APP_GPIO_CHANNEL1 1U
#define APP_GPIO_CHANNEL2 2U
#define APP_DECOUPLE_ASSERT_LEVEL 1U
#define APP_DECOUPLE_RELEASE_LEVEL 0U
#define APP_RESET_ASSERT_LEVEL 0U
#define APP_RESET_RELEASE_LEVEL 1U

#if defined(STDIN_BASEADDRESS) && defined(STDOUT_BASEADDRESS)
#define APP_HAS_CONSOLE 1
#else
#define APP_HAS_CONSOLE 0
#endif

#if APP_HAS_CONSOLE
extern char inbyte(void);
extern void outbyte(char c);
#endif

typedef enum {
    APP_RM_MUL = 0,
    APP_RM_XOR = 1
} app_rm_t;

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

typedef enum {
    APP_PARTIAL_SOURCE_NONE = 0,
    APP_PARTIAL_SOURCE_MEMORY = 1,
    APP_PARTIAL_SOURCE_SD = 2
} app_partial_source_t;

volatile u32 g_app_done;
volatile u32 g_last_status;
volatile u32 g_active_rm;
volatile u32 g_fail_count[APP_RM_COUNT];
volatile dut_result_t g_results[APP_RM_COUNT][NUM_TESTS];
volatile dut_result_t g_manual_results[APP_RM_COUNT];
volatile u32 g_last_partial_source[APP_RM_COUNT];
volatile u64 g_last_partial_addr[APP_RM_COUNT];
volatile u32 g_last_partial_size[APP_RM_COUNT];

static XAxiDma AxiDma;
static XFpga FpgaInst;
static XGpio DecoupleGpio;
static XGpio ResetGpio;
static u64 TxBuf[2] __attribute__((aligned(64)));
static u64 RxBuf[2] __attribute__((aligned(64)));

#if defined(XPAR_XUARTPS_NUM_INSTANCES) && (XPAR_XUARTPS_NUM_INSTANCES > 0)
static XUartPs ConsoleUart;
#endif
static FATFS SdFatFs;
static u32 SdMounted;
static char g_last_partial_path[APP_RM_COUNT][APP_SD_PATH_LEN];

static const dut_input_t kInputs[NUM_TESTS] = {
    {0x0000000000000007ULL, 0x0000000000000009ULL},
    {0x123456789abcdef0ULL, 0x0000000000000010ULL},
    {0xffffffffffffffffULL, 0x0000000000000002ULL},
    {0xfeedfacecafebeefULL, 0x0102030405060708ULL},
};

static const char *rm_name(app_rm_t rm)
{
    return (rm == APP_RM_XOR) ? "xor" : "mul";
}

static app_rm_t current_active_rm(void)
{
    return (g_active_rm == (u32)APP_RM_XOR) ? APP_RM_XOR : APP_RM_MUL;
}

static const char *partial_source_name(u32 source)
{
    if (source == (u32)APP_PARTIAL_SOURCE_SD) {
        return "sd";
    }
    if (source == (u32)APP_PARTIAL_SOURCE_MEMORY) {
        return "memory";
    }
    return "none";
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

static void copy_text(char *dst, unsigned int dst_len, const char *src)
{
    unsigned int idx = 0U;

    if (dst_len == 0U) {
        return;
    }

    while ((idx + 1U) < dst_len && src[idx] != '\0') {
        dst[idx] = src[idx];
        idx++;
    }

    dst[idx] = '\0';
}

static void compute_expected(app_rm_t rm, u64 a, u64 b, u64 *lo, u64 *hi)
{
    if (rm == APP_RM_XOR) {
        *lo = a ^ b;
        *hi = 0ULL;
        return;
    }

    {
        __uint128_t product = ((__uint128_t)a) * ((__uint128_t)b);
        *lo = (u64)product;
        *hi = (u64)(product >> 64);
    }
}

static int wait_for_dma_idle(int direction)
{
    u32 iter;

    for (iter = 0U; iter < DMA_TIMEOUT_ITERS; ++iter) {
        if (!XAxiDma_Busy(&AxiDma, direction)) {
            return XST_SUCCESS;
        }
    }

    return XST_FAILURE;
}

static int init_dma(void)
{
    XAxiDma_Config *cfg;

    cfg = XAxiDma_LookupConfigBaseAddr((UINTPTR)APP_DMA_BASEADDR);
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

static int init_control_gpios(void)
{
    int status;

#ifndef SDT
    status = XGpio_Initialize(&DecoupleGpio, APP_DECOUPLE_GPIO_ID);
#else
    status = XGpio_Initialize(&DecoupleGpio, (UINTPTR)APP_DECOUPLE_GPIO_BASEADDR);
#endif
    if (status != XST_SUCCESS) {
        return status;
    }

#ifndef SDT
    status = XGpio_Initialize(&ResetGpio, APP_RESET_GPIO_ID);
#else
    status = XGpio_Initialize(&ResetGpio, (UINTPTR)APP_RESET_GPIO_BASEADDR);
#endif
    if (status != XST_SUCCESS) {
        return status;
    }

    XGpio_SetDataDirection(&DecoupleGpio, APP_GPIO_CHANNEL1, 0x00000000U);
    XGpio_SetDataDirection(&DecoupleGpio, APP_GPIO_CHANNEL2, 0x00000001U);
    XGpio_SetDataDirection(&ResetGpio, APP_GPIO_CHANNEL1, 0x00000000U);

    return XST_SUCCESS;
}

static int init_fpga_loader(void)
{
    return (int)XFpga_Initialize(&FpgaInst);
}

static int mount_sd_card(void)
{
    FRESULT result;

    if (SdMounted != 0U) {
        return XST_SUCCESS;
    }

    result = f_mount(&SdFatFs, APP_SD_MOUNT_PATH, 0);
    if (result != FR_OK) {
        APP_PRINTF("f_mount(%s) failed with code %u.\r\n",
                   APP_SD_MOUNT_PATH, (unsigned int)result);
        return XST_FAILURE;
    }

    SdMounted = 1U;
    return XST_SUCCESS;
}

static u32 read_decouple_request(void)
{
    return XGpio_DiscreteRead(&DecoupleGpio, APP_GPIO_CHANNEL1) & 0x1U;
}

static u32 read_decouple_status(void)
{
    return XGpio_DiscreteRead(&DecoupleGpio, APP_GPIO_CHANNEL2) & 0x1U;
}

static u32 read_resetn_level(void)
{
    return XGpio_DiscreteRead(&ResetGpio, APP_GPIO_CHANNEL1) & 0x1U;
}

static void write_decouple_request(u32 level)
{
    XGpio_DiscreteWrite(&DecoupleGpio, APP_GPIO_CHANNEL1, level & 0x1U);
}

static void write_resetn_level(u32 level)
{
    XGpio_DiscreteWrite(&ResetGpio, APP_GPIO_CHANNEL1, level & 0x1U);
}

static int wait_for_decouple_status(u32 expected_level)
{
    u32 iter;

    for (iter = 0U; iter < GPIO_TIMEOUT_ITERS; ++iter) {
        if (read_decouple_status() == (expected_level & 0x1U)) {
            return XST_SUCCESS;
        }
    }

    return XST_FAILURE;
}

static int ensure_rp_ready_for_streaming(void)
{
    u32 resetn_level = read_resetn_level();
    u32 decouple_request = read_decouple_request();
    u32 decouple_status = read_decouple_status();

    if ((resetn_level != APP_RESET_RELEASE_LEVEL) ||
        (decouple_request != APP_DECOUPLE_RELEASE_LEVEL) ||
        (decouple_status != APP_DECOUPLE_RELEASE_LEVEL)) {
        APP_PRINTF("RP is not ready for DMA traffic.\r\n");
        APP_PRINTF("  rp_resetn=%u (%s)\r\n",
                   (unsigned int)resetn_level,
                   (resetn_level != 0U) ? "running" : "reset asserted");
        APP_PRINTF("  decouple request=%u\r\n", (unsigned int)decouple_request);
        APP_PRINTF("  decouple status=%u\r\n", (unsigned int)decouple_status);
        return XST_FAILURE;
    }

    return XST_SUCCESS;
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

    status = ensure_rp_ready_for_streaming();
    if (status != XST_SUCCESS) {
        return status;
    }

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

static int execute_case(app_rm_t rm, u64 a, u64 b, dut_result_t *result)
{
    int status;

    compute_expected(rm, a, b, &result->expected_lo, &result->expected_hi);

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

static void print_partial_image_info(app_rm_t rm)
{
    u32 source = g_last_partial_source[(u32)rm];

    APP_PRINTF("  last %s partial: %s",
               rm_name(rm), partial_source_name(source));

    if (source == (u32)APP_PARTIAL_SOURCE_MEMORY) {
        APP_PRINTF(" addr=");
        print_u64_hex("", g_last_partial_addr[(u32)rm]);
        APP_PRINTF(" size=0x%08lx\r\n",
                   (unsigned long)g_last_partial_size[(u32)rm]);
        return;
    }

    if (source == (u32)APP_PARTIAL_SOURCE_SD) {
        APP_PRINTF(" path=%s size=0x%08lx\r\n",
                   g_last_partial_path[(u32)rm],
                   (unsigned long)g_last_partial_size[(u32)rm]);
        return;
    }

    APP_PRINTF("\r\n");
}

static void show_dfx_status(void)
{
    u32 decouple_request = read_decouple_request();
    u32 decouple_status = read_decouple_status();
    u32 resetn_level = read_resetn_level();

    APP_PRINTF("\r\nDFX status\r\n");
    APP_PRINTF("  active rm: %s\r\n", rm_name(current_active_rm()));
    APP_PRINTF("  decouple request: %u\r\n", (unsigned int)decouple_request);
    APP_PRINTF("  decouple status:  %u\r\n", (unsigned int)decouple_status);
    APP_PRINTF("  rp_resetn:        %u (%s)\r\n",
               (unsigned int)resetn_level,
               (resetn_level != 0U) ? "running" : "reset asserted");
    print_partial_image_info(APP_RM_MUL);
    print_partial_image_info(APP_RM_XOR);
}

static int set_decouple_level(u32 level)
{
    write_decouple_request(level);
    return wait_for_decouple_status(level);
}

static int mark_active_rm(app_rm_t rm)
{
    g_active_rm = (u32)rm;
    APP_PRINTF("Software active RM set to %s.\r\n", rm_name(rm));
    return XST_SUCCESS;
}

static int bring_default_rm_online(void)
{
    int status;

    status = set_decouple_level(APP_DECOUPLE_RELEASE_LEVEL);
    if (status != XST_SUCCESS) {
        return status;
    }

    write_resetn_level(APP_RESET_RELEASE_LEVEL);
    g_active_rm = (u32)APP_RM_MUL;

    return XST_SUCCESS;
}

static int prepare_for_reconfiguration(void)
{
    int status;

    APP_PRINTF("\r\nPreparing RP for external partial reconfiguration.\r\n");
    APP_PRINTF("Requesting AXIS decouple...\r\n");

    status = set_decouple_level(APP_DECOUPLE_ASSERT_LEVEL);
    if (status != XST_SUCCESS) {
        APP_PRINTF("Timed out waiting for decouple status to assert.\r\n");
        g_last_status = (u32)status;
        return status;
    }

    APP_PRINTF("Asserting RP reset (active-low).\r\n");
    write_resetn_level(APP_RESET_ASSERT_LEVEL);
    g_last_status = XST_SUCCESS;

    APP_PRINTF("RP is isolated and held in reset.\r\n");
    APP_PRINTF("Load the partial bitstream externally, then use resume.\r\n");
    return XST_SUCCESS;
}

static int resume_after_reconfiguration(app_rm_t rm)
{
    int status;

    APP_PRINTF("\r\nResuming RP after external load of %s.\r\n", rm_name(rm));
    APP_PRINTF("Releasing RP reset.\r\n");
    write_resetn_level(APP_RESET_RELEASE_LEVEL);

    APP_PRINTF("Clearing AXIS decouple request...\r\n");
    status = set_decouple_level(APP_DECOUPLE_RELEASE_LEVEL);
    if (status != XST_SUCCESS) {
        APP_PRINTF("Timed out waiting for decouple status to clear.\r\n");
        g_last_status = (u32)status;
        return status;
    }

    g_active_rm = (u32)rm;
    g_last_status = XST_SUCCESS;
    APP_PRINTF("RP is back online with active RM=%s.\r\n", rm_name(rm));
    return XST_SUCCESS;
}

static void remember_partial_image_from_memory(app_rm_t rm, UINTPTR bit_addr, u32 bit_size)
{
    g_last_partial_source[(u32)rm] = (u32)APP_PARTIAL_SOURCE_MEMORY;
    g_last_partial_addr[(u32)rm] = (u64)bit_addr;
    g_last_partial_size[(u32)rm] = bit_size;
    g_last_partial_path[(u32)rm][0] = '\0';
}

static void remember_partial_image_from_sd(app_rm_t rm, const char *path, u32 bit_size)
{
    g_last_partial_source[(u32)rm] = (u32)APP_PARTIAL_SOURCE_SD;
    g_last_partial_addr[(u32)rm] = 0ULL;
    g_last_partial_size[(u32)rm] = bit_size;
    copy_text(g_last_partial_path[(u32)rm], APP_SD_PATH_LEN, path);
}

static int program_partial_bitstream(app_rm_t rm, UINTPTR bit_addr, u32 bit_size,
                                     const char *origin_desc)
{
    int status;
    u32 fpga_status;

    APP_PRINTF("\r\nLoading %s partial bitstream through xilfpga.\r\n", rm_name(rm));
    APP_PRINTF("  source=%s\r\n", origin_desc);
    APP_PRINTF("  address=");
    print_u64_hex("", (u64)bit_addr);
    APP_PRINTF(" size=0x%08lx\r\n", (unsigned long)bit_size);

    status = prepare_for_reconfiguration();
    if (status != XST_SUCCESS) {
        return status;
    }

    Xil_DCacheFlushRange(bit_addr, bit_size);
    fpga_status = XFpga_BitStream_Load(&FpgaInst, bit_addr, (UINTPTR)NULL,
                                       bit_size, XFPGA_PARTIAL_EN);
    if (fpga_status != XFPGA_SUCCESS) {
        APP_PRINTF("XFpga_BitStream_Load failed with status=0x%08lx\r\n",
                   (unsigned long)fpga_status);
        APP_PRINTF("RP remains decoupled and held in reset for safety.\r\n");
        g_last_status = fpga_status;
        return (int)fpga_status;
    }

    status = resume_after_reconfiguration(rm);
    if (status != XST_SUCCESS) {
        return status;
    }

    APP_PRINTF("xilfpga load complete for %s.\r\n", rm_name(rm));
    return XST_SUCCESS;
}

static int load_partial_bitstream_from_memory(app_rm_t rm, UINTPTR bit_addr, u32 bit_size)
{
    int status = program_partial_bitstream(rm, bit_addr, bit_size, "memory");

    if (status == XST_SUCCESS) {
        remember_partial_image_from_memory(rm, bit_addr, bit_size);
    }

    return status;
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

static int prompt_for_u32(const char *prompt, u32 *value)
{
    u64 tmp = 0ULL;
    int status = prompt_for_u64(prompt, &tmp);

    if (status != XST_SUCCESS) {
        return status;
    }

    if ((tmp == 0ULL) || (tmp > 0xffffffffULL)) {
        APP_PRINTF("Value must be in range 1..0xffffffff.\r\n");
        return XST_FAILURE;
    }

    *value = (u32)tmp;
    return XST_SUCCESS;
}

static int prompt_for_text(const char *prompt, char *buf, unsigned int buf_len)
{
    APP_PRINTF("%s", prompt);
    (void)read_line(buf, buf_len);

    if (buf[0] == '\0') {
        return APP_STATUS_CANCEL;
    }

    return XST_SUCCESS;
}

static int normalize_sd_path(const char *input, char *normalized, unsigned int normalized_len)
{
    unsigned int input_len;
    unsigned int prefix_len;

    while (isspace((unsigned char)*input)) {
        input++;
    }

    input_len = (unsigned int)strlen(input);
    while ((input_len > 0U) && isspace((unsigned char)input[input_len - 1U])) {
        input_len--;
    }

    if (input_len == 0U) {
        return XST_FAILURE;
    }

    if (strchr(input, ':') != NULL) {
        if ((input_len + 1U) > normalized_len) {
            return XST_FAILURE;
        }
        memcpy(normalized, input, input_len);
        normalized[input_len] = '\0';
        return XST_SUCCESS;
    }

    prefix_len = (unsigned int)strlen(APP_SD_MOUNT_PATH);
    if ((prefix_len + input_len + 1U) > normalized_len) {
        return XST_FAILURE;
    }

    memcpy(normalized, APP_SD_MOUNT_PATH, prefix_len);
    memcpy(normalized + prefix_len, input, input_len);
    normalized[prefix_len + input_len] = '\0';
    return XST_SUCCESS;
}

static int prompt_for_partial_image(app_rm_t rm, UINTPTR *addr, u32 *size)
{
    u64 addr64 = 0ULL;
    int status;

    APP_PRINTF("\r\nPartial image for %s. Press Enter on an empty line to cancel.\r\n",
               rm_name(rm));

    status = prompt_for_u64("  bitstream memory address = ", &addr64);
    if (status == APP_STATUS_CANCEL) {
        APP_PRINTF("Partial load cancelled.\r\n");
        return status;
    }
    if (status != XST_SUCCESS) {
        return status;
    }

    status = prompt_for_u32("  bitstream size (bytes) = ", size);
    if (status == APP_STATUS_CANCEL) {
        APP_PRINTF("Partial load cancelled.\r\n");
        return status;
    }
    if (status != XST_SUCCESS) {
        return status;
    }

    *addr = (UINTPTR)addr64;
    return XST_SUCCESS;
}

static int prompt_for_partial_image_path(app_rm_t rm, char *path, unsigned int path_len)
{
    char line[APP_SD_PATH_LEN];
    int status;

    APP_PRINTF("\r\nSD-card partial image for %s. Press Enter on an empty line to cancel.\r\n",
               rm_name(rm));
    APP_PRINTF("Use 0:/u_rp_rp_%s_partial.bit or enter a filename to use 0:/.\r\n",
               rm_name(rm));

    status = prompt_for_text("  bitstream file path = ", line, sizeof(line));
    if (status == APP_STATUS_CANCEL) {
        APP_PRINTF("Partial load cancelled.\r\n");
        return status;
    }

    if (normalize_sd_path(line, path, path_len) != XST_SUCCESS) {
        APP_PRINTF("Invalid SD path.\r\n");
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

static int allocate_sd_buffer(u32 bit_size, void **raw_alloc, UINTPTR *aligned_addr)
{
    size_t alloc_size;
    UINTPTR aligned;
    void *raw;

    alloc_size = (size_t)bit_size + (size_t)(APP_SD_ALLOC_ALIGN - 1U);
    raw = malloc(alloc_size);
    if (raw == NULL) {
        return XST_FAILURE;
    }

    aligned = ((UINTPTR)raw + (UINTPTR)(APP_SD_ALLOC_ALIGN - 1U)) &
              ~((UINTPTR)APP_SD_ALLOC_ALIGN - 1U);

    *raw_alloc = raw;
    *aligned_addr = aligned;
    return XST_SUCCESS;
}

static int read_partial_image_from_sd(const char *path, UINTPTR *bit_addr, u32 *bit_size,
                                      void **raw_alloc)
{
    FIL file;
    FRESULT result;
    FSIZE_t file_size;
    u64 file_size_u64;
    UINTPTR aligned_addr;
    void *raw = NULL;
    UINT bytes_read = 0U;
    int status;

    status = mount_sd_card();
    if (status != XST_SUCCESS) {
        return status;
    }

    result = f_open(&file, path, FA_READ);
    if (result != FR_OK) {
        APP_PRINTF("f_open(%s) failed with code %u.\r\n",
                   path, (unsigned int)result);
        return XST_FAILURE;
    }

    file_size = f_size(&file);
    file_size_u64 = (u64)file_size;
    if ((file_size_u64 == 0ULL) || (file_size_u64 > 0xffffffffULL)) {
        APP_PRINTF("Invalid partial size for %s: 0x%08lx%08lx\r\n",
                   path,
                   (unsigned long)(u32)(file_size_u64 >> 32),
                   (unsigned long)(u32)(file_size_u64 & 0xffffffffU));
        (void)f_close(&file);
        return XST_FAILURE;
    }

    status = allocate_sd_buffer((u32)file_size_u64, &raw, &aligned_addr);
    if (status != XST_SUCCESS) {
        APP_PRINTF("Failed to allocate 0x%08lx bytes for %s.\r\n",
                   (unsigned long)(u32)file_size_u64, path);
        (void)f_close(&file);
        return status;
    }

    result = f_read(&file, (void *)aligned_addr, (UINT)file_size_u64, &bytes_read);
    (void)f_close(&file);
    if ((result != FR_OK) || (bytes_read != (UINT)file_size_u64)) {
        APP_PRINTF("f_read(%s) failed with code %u, read=%u expected=%u.\r\n",
                   path, (unsigned int)result, (unsigned int)bytes_read,
                   (unsigned int)file_size_u64);
        free(raw);
        return XST_FAILURE;
    }

    *bit_addr = aligned_addr;
    *bit_size = (u32)file_size_u64;
    *raw_alloc = raw;
    return XST_SUCCESS;
}

static int load_partial_bitstream_from_sd(app_rm_t rm, const char *path)
{
    UINTPTR bit_addr = 0U;
    u32 bit_size = 0U;
    void *raw_alloc = NULL;
    int status;

    APP_PRINTF("\r\nReading %s partial bitstream from SD card.\r\n", rm_name(rm));
    APP_PRINTF("  path=%s\r\n", path);

    status = read_partial_image_from_sd(path, &bit_addr, &bit_size, &raw_alloc);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = program_partial_bitstream(rm, bit_addr, bit_size, path);
    free(raw_alloc);

    if (status == XST_SUCCESS) {
        remember_partial_image_from_sd(rm, path, bit_size);
    }

    return status;
}

static void print_menu(void)
{
    APP_PRINTF("\r\n");
    APP_PRINTF("dut64_dfx_dma_cli\r\n");
    APP_PRINTF("  active rm: %s\r\n", rm_name(current_active_rm()));
    APP_PRINTF("  decouple req/status: %u/%u\r\n",
               (unsigned int)read_decouple_request(),
               (unsigned int)read_decouple_status());
    APP_PRINTF("  rp_resetn: %u (%s)\r\n",
               (unsigned int)read_resetn_level(),
               (read_resetn_level() != 0U) ? "running" : "reset asserted");
    APP_PRINTF("  1) Run smoke test (active RM)\r\n");
    APP_PRINTF("  2) Manual operation (active RM)\r\n");
    APP_PRINTF("  3) Show DFX status\r\n");
    APP_PRINTF("  4) Prepare RP for partial reconfiguration\r\n");
    APP_PRINTF("  5) Resume RP after loading mul\r\n");
    APP_PRINTF("  6) Resume RP after loading xor\r\n");
    APP_PRINTF("  l) Load mul partial from memory via xilfpga\r\n");
    APP_PRINTF("  k) Load xor partial from memory via xilfpga\r\n");
    APP_PRINTF("  u) Load mul partial from SD card via xilfpga\r\n");
    APP_PRINTF("  i) Load xor partial from SD card via xilfpga\r\n");
    APP_PRINTF("  7) Assert decouple\r\n");
    APP_PRINTF("  8) Release decouple\r\n");
    APP_PRINTF("  9) Assert RP reset\r\n");
    APP_PRINTF("  a) Release RP reset\r\n");
    APP_PRINTF("  m) Mark active RM as mul (software only)\r\n");
    APP_PRINTF("  x) Mark active RM as xor (software only)\r\n");
    APP_PRINTF("  q) Quit\r\n");
    APP_PRINTF("Select option: ");
}

static int run_manual_operation(app_rm_t rm)
{
    dut_result_t result = {0};
    u64 a = 0ULL;
    u64 b = 0ULL;
    int status;

    APP_PRINTF("\r\nManual operation for active RM=%s. Press Enter on an empty line to cancel.\r\n",
               rm_name(rm));

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

    APP_PRINTF("Running %s with ", rm_name(rm));
    print_u64_hex("a=", a);
    APP_PRINTF(" ");
    print_u64_hex("b=", b);
    APP_PRINTF("\r\n");

    status = execute_case(rm, a, b, &result);
    g_manual_results[(u32)rm] = result;
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        APP_PRINTF("DMA transfer failed during manual operation.\r\n");
        return status;
    }

    report_result(&result);
    g_last_status = result.passed ? XST_SUCCESS : XST_FAILURE;

    if (result.passed) {
        APP_PRINTF("Manual operation (%s): PASS\r\n", rm_name(rm));
    } else {
        APP_PRINTF("Manual operation (%s): FAIL\r\n", rm_name(rm));
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

static int run_smoke_tests(app_rm_t rm)
{
    u32 i;

    g_fail_count[(u32)rm] = 0U;
    APP_PRINTF("\r\nRunning smoke test for active RM=%s\r\n", rm_name(rm));

    for (i = 0U; i < NUM_TESTS; ++i) {
        dut_result_t result = {0};
        int status;

        APP_PRINTF("test %u: ", (unsigned int)i);
        print_u64_hex("a=", kInputs[i].a);
        APP_PRINTF(" ");
        print_u64_hex("b=", kInputs[i].b);
        APP_PRINTF("\r\n");

        status = execute_case(rm, kInputs[i].a, kInputs[i].b, &result);
        g_results[(u32)rm][i] = result;
        if (status != XST_SUCCESS) {
            g_last_status = (u32)status;
            g_fail_count[(u32)rm]++;
            APP_PRINTF("DMA transfer failed on test %u for %s\r\n",
                       (unsigned int)i, rm_name(rm));
            return status;
        }

        if (!result.passed) {
            g_fail_count[(u32)rm]++;
            APP_PRINTF("Smoke test mismatch on test %u for %s\r\n",
                       (unsigned int)i, rm_name(rm));
        }

        report_result(&result);
    }

    g_last_status = (g_fail_count[(u32)rm] == 0U) ? XST_SUCCESS : XST_FAILURE;

    if (g_fail_count[(u32)rm] == 0U) {
        APP_PRINTF("Smoke test (%s): PASS\r\n", rm_name(rm));
    } else {
        APP_PRINTF("Smoke test (%s): FAIL count=%u\r\n",
                   rm_name(rm),
                   (unsigned int)g_fail_count[(u32)rm]);
    }

    return (int)g_last_status;
}

int main(void)
{
    int status;
    u32 i;

    g_app_done = 0U;
    g_last_status = XST_FAILURE;
    g_active_rm = (u32)APP_RM_MUL;
    for (i = 0U; i < APP_RM_COUNT; ++i) {
        g_fail_count[i] = 0U;
        g_last_partial_source[i] = (u32)APP_PARTIAL_SOURCE_NONE;
        g_last_partial_addr[i] = 0ULL;
        g_last_partial_size[i] = 0U;
        g_last_partial_path[i][0] = '\0';
    }
    SdMounted = 0U;

    status = init_console();
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        g_app_done = 1U;
        return status;
    }

    APP_PRINTF("dut64_dfx_dma_cli: starting\r\n");
    APP_PRINTF("  dma @ 0x%08lx\r\n", (unsigned long)(u32)APP_DMA_BASEADDR);
    APP_PRINTF("  decouple gpio @ 0x%08lx\r\n", (unsigned long)(u32)APP_DECOUPLE_GPIO_BASEADDR);
    APP_PRINTF("  reset gpio @ 0x%08lx\r\n", (unsigned long)(u32)APP_RESET_GPIO_BASEADDR);
    APP_PRINTF("  note: xilfpga partial loads can use a staged memory image or a .bit file from 0:/ on the SD card.\r\n");

    status = init_dma();
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        APP_PRINTF("dut64_dfx_dma_cli: DMA init failed\r\n");
        g_app_done = 1U;
        return status;
    }

    status = init_control_gpios();
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        APP_PRINTF("dut64_dfx_dma_cli: GPIO init failed\r\n");
        g_app_done = 1U;
        return status;
    }

    status = init_fpga_loader();
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        APP_PRINTF("dut64_dfx_dma_cli: xilfpga init failed (status=0x%08lx)\r\n",
                   (unsigned long)(u32)status);
        g_app_done = 1U;
        return status;
    }

    status = bring_default_rm_online();
    if (status != XST_SUCCESS) {
        g_last_status = (u32)status;
        APP_PRINTF("dut64_dfx_dma_cli: failed to release default RP state\r\n");
        g_app_done = 1U;
        return status;
    }

    APP_PRINTF("Released default mul RP from reset and cleared decouple.\r\n");
    show_dfx_status();

#if APP_HAS_CONSOLE
    for (;;) {
        char line[APP_INPUT_BUF_LEN];

        print_menu();
        (void)read_line(line, sizeof(line));

        switch (line[0]) {
        case '1':
            (void)run_smoke_tests(current_active_rm());
            break;
        case '2':
            (void)run_manual_operation(current_active_rm());
            break;
        case '3':
            show_dfx_status();
            break;
        case '4':
            (void)prepare_for_reconfiguration();
            break;
        case '5':
            (void)resume_after_reconfiguration(APP_RM_MUL);
            break;
        case '6':
            (void)resume_after_reconfiguration(APP_RM_XOR);
            break;
        case 'l':
        case 'L':
        {
            UINTPTR bit_addr = 0U;
            u32 bit_size = 0U;
            status = prompt_for_partial_image(APP_RM_MUL, &bit_addr, &bit_size);
            if (status == XST_SUCCESS) {
                (void)load_partial_bitstream_from_memory(APP_RM_MUL, bit_addr, bit_size);
            }
            break;
        }
        case 'k':
        case 'K':
        {
            UINTPTR bit_addr = 0U;
            u32 bit_size = 0U;
            status = prompt_for_partial_image(APP_RM_XOR, &bit_addr, &bit_size);
            if (status == XST_SUCCESS) {
                (void)load_partial_bitstream_from_memory(APP_RM_XOR, bit_addr, bit_size);
            }
            break;
        }
        case 'u':
        case 'U':
        {
            char path[APP_SD_PATH_LEN];
            status = prompt_for_partial_image_path(APP_RM_MUL, path, sizeof(path));
            if (status == XST_SUCCESS) {
                (void)load_partial_bitstream_from_sd(APP_RM_MUL, path);
            }
            break;
        }
        case 'i':
        case 'I':
        {
            char path[APP_SD_PATH_LEN];
            status = prompt_for_partial_image_path(APP_RM_XOR, path, sizeof(path));
            if (status == XST_SUCCESS) {
                (void)load_partial_bitstream_from_sd(APP_RM_XOR, path);
            }
            break;
        }
        case '7':
            status = set_decouple_level(APP_DECOUPLE_ASSERT_LEVEL);
            g_last_status = (u32)status;
            APP_PRINTF((status == XST_SUCCESS) ?
                       "Decouple asserted.\r\n" :
                       "Timed out while asserting decouple.\r\n");
            break;
        case '8':
            status = set_decouple_level(APP_DECOUPLE_RELEASE_LEVEL);
            g_last_status = (u32)status;
            APP_PRINTF((status == XST_SUCCESS) ?
                       "Decouple released.\r\n" :
                       "Timed out while releasing decouple.\r\n");
            break;
        case '9':
            write_resetn_level(APP_RESET_ASSERT_LEVEL);
            g_last_status = XST_SUCCESS;
            APP_PRINTF("RP reset asserted (write 0 to active-low rp_resetn).\r\n");
            break;
        case 'a':
        case 'A':
            write_resetn_level(APP_RESET_RELEASE_LEVEL);
            g_last_status = XST_SUCCESS;
            APP_PRINTF("RP reset released (write 1 to active-low rp_resetn).\r\n");
            break;
        case 'm':
        case 'M':
            (void)mark_active_rm(APP_RM_MUL);
            g_last_status = XST_SUCCESS;
            break;
        case 'x':
        case 'X':
            (void)mark_active_rm(APP_RM_XOR);
            g_last_status = XST_SUCCESS;
            break;
        case 'q':
        case 'Q':
            APP_PRINTF("Exiting dut64_dfx_dma_cli.\r\n");
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
    status = run_smoke_tests(current_active_rm());
    g_app_done = 1U;
    return status;
#endif
}
